/*
 * gc2607_isp.c — Lightweight userspace ISP for GC2607 camera sensor
 *
 * Captures raw 10-bit Bayer GRBG from V4L2, applies:
 *   - Bilinear demosaic (full 1920x1080) or 2x2 binning (960x540, less CPU)
 *   - Black level subtraction
 *   - White balance (auto gray-world, manual, or presets)
 *   - Auto-exposure (software + hardware)
 *   - S-curve contrast + sRGB gamma via per-channel LUT
 * Outputs YUYV to v4l2loopback.
 *
 * Config: /etc/gc2607/gc2607.conf
 * Usage:  gc2607_isp <capture_dev> <output_dev> [--option value ...]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <ctype.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <limits.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/inotify.h>
#include <linux/videodev2.h>

/* ── Sensor constants (fixed hardware) ─────────────────────────────── */
#define SENSOR_W        1920
#define SENSOR_H        1080
#define LUT_SIZE        1024        /* 10-bit: values 0..1023 */
#define BLACK_LEVEL     64
#define MAX_SIGNAL      959.0f      /* 1023 - 64 */
#define EXPOSURE_MIN    4
#define EXPOSURE_MAX    2002
#define GAIN_MIN        0
#define GAIN_MAX        16
#define SENSOR_FPS      30          /* Sensor always runs at 30fps */

/* ── ISP tuning constants ───────────────────────────────────────────── */
#define WB_SMOOTHING        0.88f   /* steady-state smoothing */
#define WB_SMOOTHING_FAST   0.0f    /* first N frames: instant convergence */
#define WB_FAST_FRAMES      20      /* frames before switching to smooth */
#define WB_SUBSAMPLE        8
#define AE_SMOOTHING        0.90f
#define AE_SMOOTHING_FAST   0.50f   /* fast convergence at startup / scene change */
#define AE_FAST_FRAMES      30      /* frames of fast AE after startup/scene change */
#define AE_INTERVAL_S       0.8     /* how often to adjust hardware controls */
#define AE_SCENE_CHANGE_THR 0.4f    /* brightness ratio that triggers fast AE */
#define BRIGHTNESS_MIN      0.3f
#define BRIGHTNESS_MAX      4.0f
#define NUM_BUFFERS         4
#define CONFIG_PATH         "/etc/gc2607/gc2607.conf"

/* ── White balance preset R/B gains (green=1.0) ─────────────────────
 * Derived from typical spectral conditions; fine-tune if needed.     */
static const struct { const char *name; float r; float b; } WB_PRESETS[] = {
    { "daylight",    1.80f, 1.55f },
    { "cloudy",      2.00f, 1.40f },
    { "shade",       2.20f, 1.30f },
    { "tungsten",    1.10f, 2.40f },
    { "fluorescent", 1.50f, 2.00f },
    { NULL, 0, 0 }
};

/* ── Runtime settings (filled from config / CLI) ────────────────────── */
static int   cfg_half_res  = 0;       /* 0=1920x1080 bilinear, 1=960x540 binning */
static int   cfg_fps       = 30;      /* Output FPS 1-30 */
static float cfg_brightness= 100.0f; /* AE target 0-255 */
static int   cfg_saturation= 100;    /* 100=neutral */
/* wb_mode: "auto", "manual", or preset name */
static char  cfg_wb_mode[32] = "auto";
static float cfg_wb_red    = 1.0f;   /* used when wb_mode=manual */
static float cfg_wb_blue   = 1.0f;
static int   cfg_rotation  = 180;    /* 0 or 180 — sensor is mounted upside-down */

/* ── Derived at startup ─────────────────────────────────────────────── */
static int OUT_W, OUT_H;

/* ── State ──────────────────────────────────────────────────────────── */
static volatile sig_atomic_t running      = 1;
static volatile sig_atomic_t config_dirty = 0; /* set by inotify watcher */

static void sighup_handler(int sig) { (void)sig; config_dirty = 1; }

struct buffer { void *start; size_t length; };

/* Max-size static buffers (1920x1080x2 for YUYV) */
static uint8_t  lut_r[LUT_SIZE], lut_g[LUT_SIZE], lut_b[LUT_SIZE];
static uint8_t  yuyv_buf[SENSOR_W * SENSOR_H * 2];
static uint8_t  flip_buf[SENSOR_W * SENSOR_H * 2];

static void signal_handler(int sig) { (void)sig; running = 0; }

/* 180° rotation for YUYV: reverse row order + swap Y0/Y1 within each macropixel */
static void rotate180_yuyv(const uint8_t *src, uint8_t *dst, int w, int h)
{
    int stride = w * 2; /* bytes per row in YUYV */
    for (int y = 0; y < h; y++) {
        const uint8_t *src_row = src + (h - 1 - y) * stride;
        uint8_t       *dst_row = dst + y * stride;
        for (int x = 0; x < w / 2; x++) {
            int sx = (w / 2 - 1 - x) * 4; /* source macropixel, right to left */
            int dx = x * 4;
            dst_row[dx + 0] = src_row[sx + 2]; /* Y1 → Y0 */
            dst_row[dx + 1] = src_row[sx + 1]; /* U  → U  */
            dst_row[dx + 2] = src_row[sx + 0]; /* Y0 → Y1 */
            dst_row[dx + 3] = src_row[sx + 3]; /* V  → V  */
        }
    }
}

static int xioctl(int fd, unsigned long req, void *arg)
{
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

/* ── LUT builder ───────────────────────────────────────────────────── */
static inline uint8_t apply_lut_entry(float raw, float scale)
{
    float v = raw * scale;
    if (v > 1.0f) v = 1.0f;
    v = v * v * (3.0f - 2.0f * v);   /* S-curve */
    v = powf(v, 1.0f / 2.2f);        /* sRGB gamma */
    return (uint8_t)(v * 255.0f + 0.5f);
}

static void build_luts(float r_gain, float g_gain, float b_gain, float brightness)
{
    float sr = r_gain * brightness / MAX_SIGNAL;
    float sg = g_gain * brightness / MAX_SIGNAL;
    float sb = b_gain * brightness / MAX_SIGNAL;

    for (int i = 0; i < LUT_SIZE; i++) {
        float raw = (float)(i - BLACK_LEVEL);
        if (raw < 0.0f) raw = 0.0f;
        lut_r[i] = apply_lut_entry(raw, sr);
        lut_g[i] = apply_lut_entry(raw, sg);
        lut_b[i] = apply_lut_entry(raw, sb);
    }
}

/* ── RGB→YUYV (full-range) ─────────────────────────────────────────── */
static inline void rgb_to_yuyv(uint8_t r0, uint8_t g0, uint8_t b0,
                                uint8_t r1, uint8_t g1, uint8_t b1,
                                uint8_t *out)
{
    int y0 = (77 * r0 + 150 * g0 + 29 * b0) >> 8;
    int y1 = (77 * r1 + 150 * g1 + 29 * b1) >> 8;
    int u  = ((-43 * r0 - 84 * g0 + 127 * b0) >> 8) + 128;
    int v  = ((127 * r0 - 106 * g0 - 21 * b0) >> 8) + 128;

    u = ((u - 128) * cfg_saturation / 100) + 128;
    v = ((v - 128) * cfg_saturation / 100) + 128;

#define CLAMP(x, lo, hi) ((x) < (lo) ? (lo) : ((x) > (hi) ? (hi) : (x)))
    out[0] = (uint8_t)CLAMP(y0, 0, 255);
    out[1] = (uint8_t)CLAMP(u,  0, 255);
    out[2] = (uint8_t)CLAMP(y1, 0, 255);
    out[3] = (uint8_t)CLAMP(v,  0, 255);
#undef CLAMP
}

/* ── Bayer helpers ─────────────────────────────────────────────────── */
static inline uint16_t bayer_at(const uint16_t *b, int r, int c)
{
    if (r < 0) r = 0; else if (r >= SENSOR_H) r = SENSOR_H - 1;
    if (c < 0) c = 0; else if (c >= SENSOR_W) c = SENSOR_W - 1;
    return b[r * SENSOR_W + c];
}

static inline uint16_t clamp10(int v)
{
    return (uint16_t)(v < 0 ? 0 : (v >= LUT_SIZE ? LUT_SIZE - 1 : v));
}

/* ── Full-resolution bilinear demosaic (1920x1080) ─────────────────── */
static void demosaic_full(const uint16_t *bayer,
                          float *out_r, float *out_g, float *out_b, int *out_n)
{
    double rs = 0, gs = 0, bs = 0;
    int n = 0;

    for (int r = 0; r < SENSOR_H; r++) {
        int odd_row = r & 1;
        uint8_t *row = yuyv_buf + r * SENSOR_W * 2;

        for (int c = 0; c < SENSOR_W; c += 2) {
            uint16_t R0, G0, B0, R1, G1, B1;

            if (!odd_row) {
                /* (r,c)=G  (r,c+1)=R */
                G0 = bayer_at(bayer, r, c);
                R0 = clamp10(((int)bayer_at(bayer,r,c-1)+bayer_at(bayer,r,c+1))>>1);
                B0 = clamp10(((int)bayer_at(bayer,r-1,c)+bayer_at(bayer,r+1,c))>>1);

                R1 = bayer_at(bayer, r, c+1);
                G1 = clamp10(((int)bayer_at(bayer,r,c)+bayer_at(bayer,r,c+2)+
                               bayer_at(bayer,r-1,c+1)+bayer_at(bayer,r+1,c+1))>>2);
                B1 = clamp10(((int)bayer_at(bayer,r-1,c)+bayer_at(bayer,r-1,c+2)+
                               bayer_at(bayer,r+1,c)+bayer_at(bayer,r+1,c+2))>>2);
            } else {
                /* (r,c)=B  (r,c+1)=G */
                B0 = bayer_at(bayer, r, c);
                G0 = clamp10(((int)bayer_at(bayer,r,c-1)+bayer_at(bayer,r,c+1)+
                               bayer_at(bayer,r-1,c)+bayer_at(bayer,r+1,c))>>2);
                R0 = clamp10(((int)bayer_at(bayer,r-1,c-1)+bayer_at(bayer,r-1,c+1)+
                               bayer_at(bayer,r+1,c-1)+bayer_at(bayer,r+1,c+1))>>2);

                G1 = bayer_at(bayer, r, c+1);
                R1 = clamp10(((int)bayer_at(bayer,r-1,c+1)+bayer_at(bayer,r+1,c+1))>>1);
                B1 = clamp10(((int)bayer_at(bayer,r,c)+bayer_at(bayer,r,c+2))>>1);
            }

            rgb_to_yuyv(lut_r[R0],lut_g[G0],lut_b[B0],
                        lut_r[R1],lut_g[G1],lut_b[B1],
                        row + c * 2);

            /* WB stats from true-color Bayer pixels (subsampled) */
            if ((r & (WB_SUBSAMPLE-1))==0 && (c & (WB_SUBSAMPLE-1))==0) {
                float rv, gv, bv;
                if (!odd_row) {
                    gv = (float)G0 - BLACK_LEVEL;
                    rv = (float)R1 - BLACK_LEVEL;
                    bv = (float)bayer_at(bayer, r+1, c) - BLACK_LEVEL;
                } else {
                    bv = (float)B0 - BLACK_LEVEL;
                    gv = (float)G1 - BLACK_LEVEL;
                    rv = (float)bayer_at(bayer, r-1, c+1) - BLACK_LEVEL;
                }
                if (rv > 0 && gv > 0 && bv > 0) {
                    rs += rv; gs += gv; bs += bv; n++;
                }
            }
        }
    }

    if (n > 0) { *out_r = (float)(rs/n); *out_g = (float)(gs/n); *out_b = (float)(bs/n); }
    else        { *out_r = *out_g = *out_b = 0.0f; }
    *out_n = n;
}

/* ── Half-resolution 2x2 binning (960x540, lower CPU) ─────────────── */
static void demosaic_half(const uint16_t *bayer,
                          float *out_r, float *out_g, float *out_b, int *out_n)
{
    double rs = 0, gs = 0, bs = 0;
    int n = 0;

    for (int oy = 0; oy < OUT_H; oy++) {
        const uint16_t *row0 = bayer + (oy*2)   * SENSOR_W;
        const uint16_t *row1 = bayer + (oy*2+1) * SENSOR_W;
        uint8_t *out_row = yuyv_buf + oy * OUT_W * 2;

        for (int ox = 0; ox < OUT_W; ox += 2) {
            int bx0 = ox * 2, bx1 = (ox+1) * 2;

            /* Block 0 */
            uint16_t g1_0=row0[bx0], r_0=row0[bx0+1];
            uint16_t b_0 =row1[bx0], g2_0=row1[bx0+1];
            /* Block 1 */
            uint16_t g1_1=row0[bx1], r_1=row0[bx1+1];
            uint16_t b_1 =row1[bx1], g2_1=row1[bx1+1];

            uint16_t gavg0 = clamp10((int)(g1_0+g2_0)>>1);
            uint16_t gavg1 = clamp10((int)(g1_1+g2_1)>>1);

            rgb_to_yuyv(lut_r[clamp10(r_0)], lut_g[gavg0], lut_b[clamp10(b_0)],
                        lut_r[clamp10(r_1)], lut_g[gavg1], lut_b[clamp10(b_1)],
                        out_row + ox*2);

            if ((oy & (WB_SUBSAMPLE-1))==0 && (ox & (WB_SUBSAMPLE-1))==0) {
                float rv=(float)r_0-BLACK_LEVEL, gv=(float)gavg0-BLACK_LEVEL, bv=(float)b_0-BLACK_LEVEL;
                if (rv>0 && gv>0 && bv>0) { rs+=rv; gs+=gv; bs+=bv; n++; }
            }
        }
    }

    if (n > 0) { *out_r=(float)(rs/n); *out_g=(float)(gs/n); *out_b=(float)(bs/n); }
    else        { *out_r=*out_g=*out_b=0.0f; }
    *out_n = n;
}

/* ── Sensor subdev / controls ──────────────────────────────────────── */
static int find_sensor_subdev(char *path, size_t pathlen)
{
    char dev[64];
    for (int i = 0; i < 16; i++) {
        snprintf(dev, sizeof(dev), "/dev/v4l-subdev%d", i);
        int fd = open(dev, O_RDWR);
        if (fd < 0) continue;
        struct v4l2_queryctrl qc = { .id = V4L2_CID_EXPOSURE };
        int ok = (xioctl(fd, VIDIOC_QUERYCTRL, &qc) == 0);
        close(fd);
        if (ok) { snprintf(path, pathlen, "%s", dev); return 0; }
    }
    return -1;
}

static void set_sensor_controls(const char *path, int exposure, int gain)
{
    int fd = open(path, O_RDWR);
    if (fd < 0) return;
    struct v4l2_control c;
    c.id = V4L2_CID_EXPOSURE;    c.value = exposure; xioctl(fd, VIDIOC_S_CTRL, &c);
    c.id = V4L2_CID_ANALOGUE_GAIN; c.value = gain;   xioctl(fd, VIDIOC_S_CTRL, &c);
    close(fd);
}

/* ── V4L2 capture setup ─────────────────────────────────────────────── */
static int open_capture(const char *dev, struct buffer *bufs, int *n)
{
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open capture"); return -1; }

    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = SENSOR_W;
    fmt.fmt.pix.height = SENSOR_H;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_SGRBG10;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) { perror("S_FMT capture"); close(fd); return -1; }

    struct v4l2_requestbuffers req = {0};
    req.count = NUM_BUFFERS; req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) { perror("REQBUFS"); close(fd); return -1; }
    *n = req.count;

    for (int i = 0; i < *n; i++) {
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; buf.memory = V4L2_MEMORY_MMAP; buf.index = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) { perror("QUERYBUF"); close(fd); return -1; }
        bufs[i].length = buf.length;
        bufs[i].start  = mmap(NULL, buf.length, PROT_READ|PROT_WRITE, MAP_SHARED, fd, buf.m.offset);
        if (bufs[i].start == MAP_FAILED) { perror("mmap"); close(fd); return -1; }
    }
    for (int i = 0; i < *n; i++) {
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; buf.memory = V4L2_MEMORY_MMAP; buf.index = i;
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) { perror("QBUF init"); close(fd); return -1; }
    }
    enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &t) < 0) { perror("STREAMON"); close(fd); return -1; }
    return fd;
}

static int open_output(const char *dev)
{
    int fd = open(dev, O_RDWR | O_NONBLOCK);
    if (fd < 0) { perror("open output"); return -1; }
    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width       = OUT_W;
    fmt.fmt.pix.height      = OUT_H;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field       = V4L2_FIELD_NONE;
    fmt.fmt.pix.sizeimage   = OUT_W * OUT_H * 2;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) { perror("S_FMT output"); close(fd); return -1; }
    return fd;
}

/* ── Config file parser ─────────────────────────────────────────────── */
static void load_config(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;
        char key[64] = {0}, val[64] = {0};
        if (sscanf(p, "%63[^= \t\n]%*[ \t=]%63[^\n#]", key, val) != 2) continue;
        /* trim trailing spaces in val */
        int vl = (int)strlen(val);
        while (vl > 0 && (val[vl-1]==' '||val[vl-1]=='\t')) val[--vl]='\0';

        if (!strcmp(key,"resolution")) {
            if (!strcmp(val,"960x540") || !strcmp(val,"half")) cfg_half_res=1;
            else cfg_half_res=0;
        } else if (!strcmp(key,"fps")) {
            cfg_fps = atoi(val);
        } else if (!strcmp(key,"brightness")) {
            cfg_brightness = (float)atof(val);
        } else if (!strcmp(key,"saturation")) {
            cfg_saturation = atoi(val);
        } else if (!strcmp(key,"wb")) {
            snprintf(cfg_wb_mode, sizeof(cfg_wb_mode), "%s", val);
        } else if (!strcmp(key,"wb_red")) {
            cfg_wb_red = (float)atof(val);
        } else if (!strcmp(key,"wb_blue")) {
            cfg_wb_blue = (float)atof(val);
        } else if (!strcmp(key,"rotation")) {
            cfg_rotation = atoi(val);
        }
    }
    fclose(f);
}

static void apply_arg(const char *key, const char *val)
{
    if (!strcmp(key,"resolution")) {
        if (!strcmp(val,"960x540")||!strcmp(val,"half")) cfg_half_res=1; else cfg_half_res=0;
    } else if (!strcmp(key,"fps"))        { cfg_fps        = atoi(val);
    } else if (!strcmp(key,"brightness")) { cfg_brightness = (float)atof(val);
    } else if (!strcmp(key,"saturation")) { cfg_saturation = atoi(val);
    } else if (!strcmp(key,"wb"))         { snprintf(cfg_wb_mode,sizeof(cfg_wb_mode),"%s",val);
    } else if (!strcmp(key,"wb_red"))     { cfg_wb_red     = (float)atof(val);
    } else if (!strcmp(key,"wb_blue"))    { cfg_wb_blue    = (float)atof(val);
    } else if (!strcmp(key,"rotation"))   { cfg_rotation   = atoi(val);
    }
}

/* ── Consumer detection via /proc/PID/fd ───────────────────────────── *
 * Returns number of processes (other than self) that have dev open.   *
 * Called infrequently (~every 2 s) so /proc overhead is acceptable.  */
static int count_readers(const char *dev)
{
    struct stat target;
    if (stat(dev, &target) < 0) return 0;

    DIR *proc = opendir("/proc");
    if (!proc) return 0;

    pid_t my_pid = getpid();
    int found = 0;
    struct dirent *pe;

    while ((pe = readdir(proc)) != NULL && !found) {
        if (!isdigit((unsigned char)pe->d_name[0])) continue;
        pid_t pid = (pid_t)atoi(pe->d_name);
        if (pid == my_pid) continue;

        char fddir[64];
        snprintf(fddir, sizeof(fddir), "/proc/%d/fd", pid);
        DIR *fds = opendir(fddir);
        if (!fds) continue;

        struct dirent *fe;
        while ((fe = readdir(fds)) != NULL && !found) {
            if (fe->d_name[0] == '.') continue;
            char link[PATH_MAX];
            int n = snprintf(link, sizeof(link), "/proc/%d/fd/%s", pid, fe->d_name);
            if (n < 0 || n >= (int)sizeof(link))
                continue;
            struct stat lst;
            if (stat(link, &lst) == 0 &&
                lst.st_dev == target.st_dev &&
                lst.st_ino == target.st_ino)
                found++;
        }
        closedir(fds);
    }
    closedir(proc);
    return found;
}

static void print_usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s <capture_dev> <output_dev> [options]\n"
        "\n"
        "Options (also settable in /etc/gc2607/gc2607.conf):\n"
        "  --resolution 1920x1080|960x540   output size (default: 1920x1080)\n"
        "  --fps N                          output fps 1-30 (default: 30)\n"
        "  --brightness N                   AE target 0-255 (default: 100)\n"
        "  --saturation N                   100=neutral (default: 100)\n"
        "  --wb auto|daylight|cloudy|shade|tungsten|fluorescent|manual\n"
        "  --wb_red N                       manual WB red gain (default: 1.0)\n"
        "  --wb_blue N                      manual WB blue gain (default: 1.0)\n"
        "\n"
        "Examples:\n"
        "  %s /dev/video1 /dev/video50 --wb daylight --fps 15\n"
        "  %s /dev/video1 /dev/video50 --resolution 960x540 --brightness 120\n"
        "  %s /dev/video1 /dev/video50 --wb manual --wb_red 1.8 --wb_blue 1.6\n",
        prog, prog, prog, prog);
}

/* ── main ───────────────────────────────────────────────────────────── */
int main(int argc, char *argv[])
{
    const char *capture_dev = NULL, *output_dev = NULL;

    /* 1. Load config file first (CLI args override it) */
    load_config("/etc/gc2607/gc2607.conf");

    /* 2. Parse CLI */
    int positional = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i],"--help") || !strcmp(argv[i],"-h")) {
            print_usage(argv[0]); return 0;
        } else if (argv[i][0]=='-' && argv[i][1]=='-' && i+1 < argc) {
            apply_arg(argv[i]+2, argv[i+1]);
            i++;
        } else if (argv[i][0] != '-') {
            if      (positional==0) capture_dev = argv[i];
            else if (positional==1) output_dev  = argv[i];
            positional++;
        }
    }
    if (!capture_dev) capture_dev = "/dev/video1";
    if (!output_dev)  output_dev  = "/dev/video50";

    /* 3. Validate & apply settings */
    if (cfg_fps < 1)          cfg_fps = 1;
    if (cfg_fps > SENSOR_FPS) cfg_fps = SENSOR_FPS;
    if (cfg_brightness < 1.0f)   cfg_brightness = 1.0f;
    if (cfg_brightness > 254.0f) cfg_brightness = 254.0f;
    if (cfg_saturation < 0)   cfg_saturation = 0;
    if (cfg_saturation > 400) cfg_saturation = 400;

    OUT_W = cfg_half_res ? SENSOR_W/2 : SENSOR_W;
    OUT_H = cfg_half_res ? SENSOR_H/2 : SENSOR_H;

    /* 4. Determine WB mode */
    int wb_auto = 0;
    float wb_r = 1.0f, wb_b = 1.0f;

    if (!strcmp(cfg_wb_mode, "auto")) {
        wb_auto = 1;
    } else if (!strcmp(cfg_wb_mode, "manual")) {
        wb_r = cfg_wb_red;
        wb_b = cfg_wb_blue;
    } else {
        int found = 0;
        for (int i = 0; WB_PRESETS[i].name; i++) {
            if (!strcmp(cfg_wb_mode, WB_PRESETS[i].name)) {
                wb_r = WB_PRESETS[i].r;
                wb_b = WB_PRESETS[i].b;
                found = 1;
                break;
            }
        }
        if (!found) {
            fprintf(stderr, "[gc2607_isp] Unknown wb mode '%s', using auto\n", cfg_wb_mode);
            wb_auto = 1;
        }
    }

    /* 5. Frame skip interval for FPS limiting */
    int skip_every = SENSOR_FPS / cfg_fps;   /* process 1 of every N frames */
    if (skip_every < 1) skip_every = 1;

    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("[gc2607_isp] Starting\n");
    printf("[gc2607_isp]   capture=%s output=%s\n", capture_dev, output_dev);
    printf("[gc2607_isp]   resolution=%dx%d fps=%d\n", OUT_W, OUT_H, cfg_fps);
    printf("[gc2607_isp]   brightness=%.0f saturation=%d\n", (double)cfg_brightness, cfg_saturation);
    printf("[gc2607_isp]   wb=%s%s\n", cfg_wb_mode,
           wb_auto ? " (gray-world auto)" : "");
    if (!wb_auto)
        printf("[gc2607_isp]   wb_red=%.2f wb_blue=%.2f\n", (double)wb_r, (double)wb_b);

    signal(SIGINT,  signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGHUP,  sighup_handler); /* kill -HUP → reload config */

    /* Sensor subdev for hardware AE */
    char subdev_path[64] = {0};
    int has_subdev = (find_sensor_subdev(subdev_path, sizeof(subdev_path)) == 0);
    if (has_subdev)
        printf("[gc2607_isp] Sensor subdev: %s\n", subdev_path);
    else
        printf("[gc2607_isp] Warning: no sensor subdev (no hardware AE)\n");

    int cur_exposure = EXPOSURE_MAX, cur_gain = GAIN_MAX;

    /* inotify: watch the config *directory* so we catch atomic renames
     * (editors and install(1) write a temp file then rename it over the
     * original, which replaces the inode — a watch on the file itself
     * would miss that event entirely).                                  */
    int inotify_fd = inotify_init1(IN_NONBLOCK);
    if (inotify_fd >= 0)
        inotify_add_watch(inotify_fd, "/etc/gc2607",
                          IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE);

    /* Output device — open once, keep open; we write frames when streaming */
    int out_fd = open_output(output_dev);
    if (out_fd < 0) return 1;

    printf("[gc2607_isp] Ready. Sensor starts only when an app opens the camera.\n");
    printf("[gc2607_isp] Config hot-reload: edit %s (changes apply immediately)\n",
           CONFIG_PATH);

    /* ISP state */
    float brightness    = 1.0f;
    float prev_bright8  = -1.0f;
    int   frame_count   = 0;
    int   output_count  = 0;
    int   ae_fast_left  = AE_FAST_FRAMES;
    int   wb_fast_left  = WB_FAST_FRAMES;

    /* Capture resources — allocated on-demand */
    struct buffer bufs[NUM_BUFFERS];
    int  n_bufs   = 0;
    int  cap_fd   = -1;
    int  streaming = 0;   /* 1 = sensor open + STREAMON */

#define READER_CHECK_INTERVAL_S  1   /* how often to poll /proc for readers */
/* Stop only after several consecutive "no readers" checks to avoid
 * rapid on/off oscillation when apps switch camera sessions. */
#define NO_READER_STOP_CHECKS    2
    struct timespec last_reader_check = {0};
    struct timespec last_ae_time      = {0};
    clock_gettime(CLOCK_MONOTONIC, &last_reader_check);
    clock_gettime(CLOCK_MONOTONIC, &last_ae_time);
    int no_reader_checks = 0;

    size_t frame_bytes = (size_t)(OUT_W * OUT_H * 2);

    while (running) {

        /* ── Reader check: start/stop sensor based on /dev/video50 usage ── */
        struct timespec now_rc;
        clock_gettime(CLOCK_MONOTONIC, &now_rc);
        double since_check = (now_rc.tv_sec  - last_reader_check.tv_sec) +
                             (now_rc.tv_nsec - last_reader_check.tv_nsec) / 1e9;

        if (since_check >= READER_CHECK_INTERVAL_S) {
            last_reader_check = now_rc;
            int readers = count_readers(output_dev);

            if (!streaming && readers > 0) {
                /* Someone opened /dev/video50 — start sensor */
                printf("[gc2607_isp] Consumer appeared — starting sensor (LED on)\n");
                cap_fd = open_capture(capture_dev, bufs, &n_bufs);
                if (cap_fd >= 0) {
                    streaming    = 1;
                    ae_fast_left = AE_FAST_FRAMES;
                    wb_fast_left = WB_FAST_FRAMES;
                    no_reader_checks = 0;
                    if (has_subdev)
                        set_sensor_controls(subdev_path, cur_exposure, cur_gain);
                    clock_gettime(CLOCK_MONOTONIC, &last_ae_time);
                } else {
                    printf("[gc2607_isp] Failed to open capture device\n");
                }
            } else if (streaming) {
                if (readers == 0) {
                    no_reader_checks++;
                    if (no_reader_checks >= NO_READER_STOP_CHECKS) {
                        /* Nobody reading for several checks — stop sensor */
                        printf("[gc2607_isp] No consumers — stopping sensor (LED off)\n");
                        enum v4l2_buf_type st = V4L2_BUF_TYPE_VIDEO_CAPTURE;
                        xioctl(cap_fd, VIDIOC_STREAMOFF, &st);
                        for (int i = 0; i < n_bufs; i++) munmap(bufs[i].start, bufs[i].length);
                        close(cap_fd);
                        cap_fd    = -1;
                        n_bufs    = 0;
                        streaming = 0;
                        frame_count = output_count = 0;
                        no_reader_checks = 0;
                    }
                } else {
                    no_reader_checks = 0;
                }
            }
        }

        /* ── Idle: nobody watching, just sleep ───────────────────────── */
        if (!streaming) {
            usleep(500000);
            continue;
        }

        /* ── Streaming ───────────────────────────────────────────────── */
        struct v4l2_buffer buf = {0};
        buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        if (xioctl(cap_fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) { usleep(1000); continue; }
            perror("VIDIOC_DQBUF"); break;
        }

        frame_count++;

        /* FPS limiter: skip frames without processing */
        if ((frame_count % skip_every) != 0) {
            xioctl(cap_fd, VIDIOC_QBUF, &buf);
            continue;
        }

        /* ── Config hot-reload (inotify + SIGHUP) ───────────────────── */
        if (config_dirty) {
            config_dirty = 0;
            load_config(CONFIG_PATH);
            OUT_W = cfg_half_res ? SENSOR_W/2 : SENSOR_W;
            OUT_H = cfg_half_res ? SENSOR_H/2 : SENSOR_H;
            /* re-parse WB mode */
            if (!strcmp(cfg_wb_mode, "auto")) {
                wb_auto = 1;
            } else if (!strcmp(cfg_wb_mode, "manual")) {
                wb_auto = 0; wb_r = cfg_wb_red; wb_b = cfg_wb_blue;
            } else {
                wb_auto = 0;
                for (int pi = 0; WB_PRESETS[pi].name; pi++) {
                    if (!strcmp(cfg_wb_mode, WB_PRESETS[pi].name)) {
                        wb_r = WB_PRESETS[pi].r; wb_b = WB_PRESETS[pi].b; break;
                    }
                }
            }
            /* trigger fast convergence after settings change */
            ae_fast_left = AE_FAST_FRAMES;
            wb_fast_left = WB_FAST_FRAMES;
            printf("[gc2607_isp] Config reloaded: res=%dx%d fps=%d bright=%.0f wb=%s\n",
                   OUT_W, OUT_H, cfg_fps, (double)cfg_brightness, cfg_wb_mode);
        }
        /* drain inotify events — set config_dirty if gc2607.conf changed */
        if (inotify_fd >= 0) {
            char ibuf[sizeof(struct inotify_event) + NAME_MAX + 1];
            ssize_t nb;
            while ((nb = read(inotify_fd, ibuf, sizeof(ibuf))) > 0) {
                /* walk possibly-multiple events in the buffer */
                for (char *p = ibuf; p < ibuf + nb; ) {
                    struct inotify_event *ev = (struct inotify_event *)p;
                    if (ev->len > 0 &&
                        strncmp(ev->name, "gc2607.conf", ev->len) == 0)
                        config_dirty = 1;
                    p += sizeof(struct inotify_event) + ev->len;
                }
            }
        }

        const uint16_t *bayer = (const uint16_t *)bufs[buf.index].start;

        /* Process frame */
        float r_mean, g_mean, b_mean;
        int   stat_count;
        build_luts(wb_r, 1.0f, wb_b, brightness);

        if (cfg_half_res)
            demosaic_half(bayer, &r_mean, &g_mean, &b_mean, &stat_count);
        else
            demosaic_full(bayer, &r_mean, &g_mean, &b_mean, &stat_count);

        /* ── Gray-world AWB ──────────────────────────────────────────── */
        if (wb_auto && r_mean > 1.0f && g_mean > 1.0f && b_mean > 1.0f) {
            float nr = g_mean / r_mean;
            float nb = g_mean / b_mean;
            if (nr > 4.0f) nr = 4.0f; else if (nr < 0.25f) nr = 0.25f;
            if (nb > 4.0f) nb = 4.0f; else if (nb < 0.25f) nb = 0.25f;
            float sm = (wb_fast_left > 0) ? WB_SMOOTHING_FAST : WB_SMOOTHING;
            wb_r = sm * wb_r + (1.0f - sm) * nr;
            wb_b = sm * wb_b + (1.0f - sm) * nb;
            if (wb_fast_left > 0) wb_fast_left--;
        }

        /* ── Software AE ─────────────────────────────────────────────── */
        float cur_bright8 = g_mean * brightness / MAX_SIGNAL * 255.0f;

        /* Scene change detection: sudden brightness shift → fast AE */
        if (prev_bright8 > 1.0f && cur_bright8 > 1.0f) {
            float ratio = cur_bright8 / prev_bright8;
            if (ratio > (1.0f + AE_SCENE_CHANGE_THR) ||
                ratio < (1.0f - AE_SCENE_CHANGE_THR)) {
                ae_fast_left = AE_FAST_FRAMES;
            }
        }
        prev_bright8 = cur_bright8;

        if (cur_bright8 > 1.0f) {
            float ae_sm = (ae_fast_left > 0) ? AE_SMOOTHING_FAST : AE_SMOOTHING;
            float ratio = cfg_brightness / cur_bright8;
            brightness = ae_sm * brightness + (1.0f - ae_sm) * (brightness * ratio);
            if (brightness < BRIGHTNESS_MIN) brightness = BRIGHTNESS_MIN;
            if (brightness > BRIGHTNESS_MAX) brightness = BRIGHTNESS_MAX;
            if (ae_fast_left > 0) ae_fast_left--;
        }

        /* ── Hardware AE (exposure + gain) ──────────────────────────── */
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - last_ae_time.tv_sec) +
                         (now.tv_nsec - last_ae_time.tv_nsec) / 1e9;
        double ae_interval = (ae_fast_left > 0) ? (AE_INTERVAL_S / 3.0) : AE_INTERVAL_S;
        if (has_subdev && elapsed >= ae_interval) {
            int changed = 0;
            if (brightness > 2.0f) {
                /* Too dark — raise exposure first, then gain */
                if (cur_exposure < EXPOSURE_MAX) {
                    cur_exposure = (int)(cur_exposure * (ae_fast_left > 0 ? 2.0 : 1.4));
                    if (cur_exposure > EXPOSURE_MAX) cur_exposure = EXPOSURE_MAX;
                } else if (cur_gain < GAIN_MAX) {
                    cur_gain += (ae_fast_left > 0 ? 3 : 1);
                    if (cur_gain > GAIN_MAX) cur_gain = GAIN_MAX;
                }
                changed = 1;
                brightness = 1.0f;
            } else if (brightness < 0.6f && (cur_exposure > EXPOSURE_MIN || cur_gain > GAIN_MIN)) {
                /* Too bright — lower gain first, then exposure */
                if (cur_gain > GAIN_MIN) {
                    cur_gain -= (ae_fast_left > 0 ? 3 : 1);
                    if (cur_gain < GAIN_MIN) cur_gain = GAIN_MIN;
                } else {
                    cur_exposure = (int)(cur_exposure * (ae_fast_left > 0 ? 0.4 : 0.75));
                    if (cur_exposure < EXPOSURE_MIN) cur_exposure = EXPOSURE_MIN;
                }
                changed = 1;
                brightness = 1.0f;
            }
            if (changed) set_sensor_controls(subdev_path, cur_exposure, cur_gain);
            last_ae_time = now;
        }

        /* Output (with optional 180° rotation) */
        const uint8_t *out_ptr = yuyv_buf;
        if (cfg_rotation == 180) {
            rotate180_yuyv(yuyv_buf, flip_buf, OUT_W, OUT_H);
            out_ptr = flip_buf;
        }
        ssize_t wr = write(out_fd, out_ptr, frame_bytes);

        /* Return buffer to capture queue */
        if (xioctl(cap_fd, VIDIOC_QBUF, &buf) < 0) { perror("VIDIOC_QBUF"); break; }

        if (wr < 0 && errno != EAGAIN) { perror("write output"); break; }

        output_count++;
        if (output_count % 150 == 0) {
            printf("[gc2607_isp] %d frames | WB: R=%.2f B=%.2f | bright=%.2f | exp=%d gain=%d\n",
                   output_count, (double)wb_r, (double)wb_b, (double)brightness,
                   cur_exposure, cur_gain);
        }
    }

    printf("[gc2607_isp] Shutdown (%d sensor frames, %d output frames)\n",
           frame_count, output_count);

    if (streaming && cap_fd >= 0) {
        enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        xioctl(cap_fd, VIDIOC_STREAMOFF, &t);
        for (int i = 0; i < n_bufs; i++) munmap(bufs[i].start, bufs[i].length);
        close(cap_fd);
    }
    close(out_fd);
    if (inotify_fd >= 0) close(inotify_fd);
    return 0;
}
