# Interactive viewer for the iCEBreaker Mandelbrot sanity check.
#
#   uv run --with pyserial --with pygame python viewer.py [port]
#
# Controls:
#   arrows (hold) / left-click ... pan
#   + / - / mouse wheel .......... zoom (wheel zooms toward the cursor)
#   [ / ] ........................ MAXIT down / up
#   f / space .................... render the current view at FULL resolution
#   p ............................ toggle "auto full-res when idle"
#   r ............................ reset to the full view
#   esc / close .................. quit
#
# It stays at a low PREVIEW resolution while you explore (so frames complete
# quickly and fill the screen); press f when you've found something to render it
# at full resolution. (Turn on auto-full with p if you prefer.)
#
# Pixel stream (FPGA -> host):  0xFF new frame, 0xFE end of scanline, else pixel.
# Control packet (host -> FPGA), 18 bytes, big-endian (matches ice_top.v):
#   0xC3  corner_x[i32]  corner_y[i32]  step[i32]  maxit[u8]  W[u16]  H[u16]   (Q4.28)

import glob
import struct
import sys
import time

import pygame
import serial

FRAC = 28
FULL_W, FULL_H = 320, 240
PREV_W, PREV_H = 64, 48           # preview res — small enough to complete fast
WIN_W, WIN_H = 640, 480
BAUD = 115200
HDR = 0xC3
SEND_MIN_DT = 0.35                # >= a preview frame time, so each frame completes
IDLE_DT = 0.4                     # "idle" = no input for this long
PAN_RATE = 0.6                    # screens/sec while an arrow is held


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbserial-*"))
    if not ports:
        sys.exit("no /dev/cu.usbserial-* found — is the board plugged in?")
    for p in ports:
        if p.endswith("B"):
            return p
    return ports[-1]


def pixel_color(b, maxit):
    if b == 0:
        return (10, 10, 20)
    t = min(b / maxit, 1.0)
    return (int(255 * t * t), int(255 * t), min(255, int(120 + 135 * (1 - t))))


class View:
    def __init__(self):
        self.reset()

    def reset(self):
        self.cx, self.cy, self.span, self.maxit = -0.5, 0.0, 3.5, 100

    def packet(self, W, H):
        step = self.span / W
        cornerx = self.cx - (W / 2) * step
        cornery = self.cy - (H / 2) * step

        def q(v):
            n = int(round(v * (1 << FRAC)))
            return max(-(1 << 31), min((1 << 31) - 1, n))

        pkt = bytearray([HDR])
        for v in (cornerx, cornery, step):
            pkt += struct.pack(">i", q(v))
        pkt += bytes([self.maxit & 0xFF])
        pkt += struct.pack(">H", W) + struct.pack(">H", H)
        return bytes(pkt)

    def zoom(self, factor, ax=0.5, ay=0.5):
        self.cx += (ax - 0.5) * self.span * (1 - factor)
        self.cy += (ay - 0.5) * self.span * (FULL_H / FULL_W) * (1 - factor)
        self.span *= factor

    def bump_maxit(self, d):
        self.maxit = max(8, min(250, self.maxit + d))


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else find_port()
    ser = serial.Serial(port, BAUD, timeout=0)
    print(f"reading/writing {port} @ {BAUD}")

    pygame.init()
    screen = pygame.display.set_mode((WIN_W, WIN_H))
    pygame.display.set_caption("iCEBreaker Mandelbrot — interactive")
    font = pygame.font.SysFont("monospace", 13)
    clock = pygame.time.Clock()

    view = View()
    cur_w, cur_h = PREV_W, PREV_H
    frame = pygame.Surface((cur_w, cur_h)); frame.fill((10, 10, 20))
    x = y = 0
    resync = True

    dirty = True
    pending_full = False
    auto_full = False
    last_input = 0.0
    last_send = 0.0
    last_full = False

    def send(W, H):
        nonlocal cur_w, cur_h, frame, resync, last_send, x, y
        ser.reset_input_buffer()
        ser.write(view.packet(W, H))
        cur_w, cur_h = W, H
        frame = pygame.Surface((cur_w, cur_h)); frame.fill((10, 10, 20))
        x = y = 0
        resync = True
        last_send = time.time()

    running = True
    while running:
        dt = clock.tick(120) / 1000.0
        now = time.time()

        for e in pygame.event.get():
            if e.type == pygame.QUIT:
                running = False
            elif e.type == pygame.KEYDOWN:
                if e.key == pygame.K_ESCAPE: running = False
                elif e.key in (pygame.K_PLUS, pygame.K_EQUALS): view.zoom(0.7); dirty = True
                elif e.key == pygame.K_MINUS: view.zoom(1 / 0.7); dirty = True
                elif e.key == pygame.K_LEFTBRACKET:  view.bump_maxit(-8); dirty = True
                elif e.key == pygame.K_RIGHTBRACKET: view.bump_maxit(8);  dirty = True
                elif e.key in (pygame.K_f, pygame.K_SPACE): pending_full = True
                elif e.key == pygame.K_p: auto_full = not auto_full
                elif e.key == pygame.K_r: view.reset(); dirty = True
                last_input = now
            elif e.type == pygame.MOUSEBUTTONDOWN:
                ax, ay = e.pos[0] / WIN_W, e.pos[1] / WIN_H
                if e.button == 1:
                    view.cx += (ax - 0.5) * view.span
                    view.cy += (ay - 0.5) * view.span * (FULL_H / FULL_W)
                elif e.button == 4: view.zoom(0.8, ax, ay)
                elif e.button == 5: view.zoom(1 / 0.8, ax, ay)
                dirty = True; last_input = now

        # continuous pan while an arrow is held
        keys = pygame.key.get_pressed()
        dx = (keys[pygame.K_RIGHT] - keys[pygame.K_LEFT]) * PAN_RATE * dt
        dy = (keys[pygame.K_DOWN] - keys[pygame.K_UP]) * PAN_RATE * dt
        if dx or dy:
            view.cx += dx * view.span
            view.cy += dy * view.span * (FULL_H / FULL_W)
            dirty = True; last_input = now

        idle = (now - last_input) > IDLE_DT
        # send policy: full on demand; otherwise preview while exploring
        if pending_full:
            send(FULL_W, FULL_H); pending_full = False; dirty = False; last_full = True
        elif dirty and (now - last_send) > SEND_MIN_DT:
            send(PREV_W, PREV_H); dirty = False; last_full = False
        elif auto_full and idle and not last_full and not dirty and (now - last_send) > SEND_MIN_DT:
            send(FULL_W, FULL_H); last_full = True

        # drain pixels
        n = ser.in_waiting
        if n:
            for b in ser.read(n):
                if b == 0xFF:
                    resync = False; x = y = 0
                    screen.blit(pygame.transform.scale(frame, (WIN_W, WIN_H)), (0, 0))
                elif resync:
                    continue
                elif b == 0xFE:
                    x = 0; y += 1
                    screen.blit(pygame.transform.scale(frame, (WIN_W, WIN_H)), (0, 0))
                else:
                    if 0 <= x < cur_w and 0 <= y < cur_h:
                        frame.set_at((x, y), pixel_color(b, view.maxit))
                    x += 1

        mode = "FULL" if last_full else "preview"
        hud = font.render(
            f"({view.cx:+.6f},{view.cy:+.6f}) span={view.span:.2e} maxit={view.maxit}  "
            f"[{mode}{' auto' if auto_full else ''}]  f=full p=auto r=reset",
            True, (200, 220, 255))
        screen.blit(hud, (6, WIN_H - 19))
        pygame.display.flip()

    ser.close()
    pygame.quit()


if __name__ == "__main__":
    main()
