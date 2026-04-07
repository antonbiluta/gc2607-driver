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
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
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
#define WB_SMOOTHING    0.85f
#define WB_SUBSAMPLE    8
#define AE_SMOOTHING    0.92f
#define AE_INTERVAL_S   1.5
#define BRIGHTNESS_MIN  0.3f
#define BRIGHTNESS_MAX  4.0f
#define NUM_BUFFERS     4

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

/* ── Derived at startup ─────────────────────────────────────────────── */
static int OUT_W, OUT_H;

/* ── State ──────────────────────────────────────────────────────────── */
static volatile sig_atomic_t running = 1;

struct buffer { void *start; size_t length; };

/* Max-size static buffers (1920x1080x2 for YUYV) */
static uint8_t  lut_r[LUT_SIZE], lut_g[LUT_SIZE], lut_b[LUT_SIZE];
static uint8_t  yuyv_buf[SENSOR_W * SENSOR_H * 2];

static void signal_handler(int sig) { (void)sig; running = 0; }

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
    int fd = open(dev, O_RDWR);
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
    }
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

    /* Sensor subdev for hardware AE */
    char subdev_path[64] = {0};
    int has_subdev = (find_sensor_subdev(subdev_path, sizeof(subdev_path)) == 0);
    if (has_subdev)
        printf("[gc2607_isp] Sensor subdev: %s\n", subdev_path);
    else
        printf("[gc2607_isp] Warning: no sensor subdev (no hardware AE)\n");

    int cur_exposure = EXPOSURE_MAX, cur_gain = GAIN_MAX;
    if (has_subdev)
        set_sensor_controls(subdev_path, cur_exposure, cur_gain);

    struct buffer bufs[NUM_BUFFERS];
    int n_bufs = 0;
    int cap_fd = open_capture(capture_dev, bufs, &n_bufs);
    if (cap_fd < 0) return 1;

    int out_fd = open_output(output_dev);
    if (out_fd < 0) { close(cap_fd); return 1; }

    printf("[gc2607_isp] Streaming %dx%d @ %dfps\n", OUT_W, OUT_H, cfg_fps);

    /* ISP state */
    float brightness   = 1.0f;
    int   frame_count  = 0;
    int   output_count = 0;

    struct timespec last_ae_time;
    clock_gettime(CLOCK_MONOTONIC, &last_ae_time);

    while (running) {
        struct v4l2_buffer buf = {0};
        buf.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        if (xioctl(cap_fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) continue;
            perror("VIDIOC_DQBUF"); break;
        }

        frame_count++;

        /* FPS limiter: skip frames without processing */
        if ((frame_count % skip_every) != 0) {
            xioctl(cap_fd, VIDIOC_QBUF, &buf);
            continue;
        }

        const uint16_t *bayer = (const uint16_t *)bufs[buf.index].start;

        /* WB gains for this frame */
        float fr = wb_auto ? wb_r : wb_r;
        float fb = wb_auto ? wb_b : wb_b;

        /* Process frame */
        float r_mean, g_mean, b_mean;
        int   stat_count;
        build_luts(fr, 1.0f, fb, brightness);

        if (cfg_half_res)
            demosaic_half(bayer, &r_mean, &g_mean, &b_mean, &stat_count);
        else
            demosaic_full(bayer, &r_mean, &g_mean, &b_mean, &stat_count);

        /* Gray-world AWB update */
        if (wb_auto && r_mean > 1.0f && g_mean > 1.0f && b_mean > 1.0f) {
            float nr = g_mean / r_mean;
            float nb = g_mean / b_mean;
            if (nr > 4.0f)  { nr = 4.0f;  }
            if (nr < 0.25f) { nr = 0.25f; }
            if (nb > 4.0f)  { nb = 4.0f;  }
            if (nb < 0.25f) { nb = 0.25f; }
            float sm = output_count < 10 ? 0.0f : WB_SMOOTHING;
            wb_r = sm * wb_r + (1.0f - sm) * nr;
            wb_b = sm * wb_b + (1.0f - sm) * nb;
        }

        /* Software AE */
        float cur_bright8 = g_mean * brightness / MAX_SIGNAL * 255.0f;
        if (cur_bright8 > 1.0f) {
            float ratio = cfg_brightness / cur_bright8;
            brightness = AE_SMOOTHING * brightness + (1.0f - AE_SMOOTHING) * (brightness * ratio);
            if (brightness < BRIGHTNESS_MIN) brightness = BRIGHTNESS_MIN;
            if (brightness > BRIGHTNESS_MAX) brightness = BRIGHTNESS_MAX;
        }

        /* Hardware AE */
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - last_ae_time.tv_sec) +
                         (now.tv_nsec - last_ae_time.tv_nsec) / 1e9;
        if (has_subdev && elapsed >= AE_INTERVAL_S) {
            if (brightness > 2.5f) {
                if (cur_exposure < EXPOSURE_MAX) {
                    cur_exposure = (int)(cur_exposure * 1.5);
                    if (cur_exposure > EXPOSURE_MAX) cur_exposure = EXPOSURE_MAX;
                } else if (cur_gain < GAIN_MAX) {
                    cur_gain += 2;
                    if (cur_gain > GAIN_MAX) cur_gain = GAIN_MAX;
                }
                set_sensor_controls(subdev_path, cur_exposure, cur_gain);
                brightness = 1.0f;
            } else if (brightness < 0.8f && (cur_exposure > EXPOSURE_MIN || cur_gain > GAIN_MIN)) {
                cur_exposure = (int)(cur_exposure * 0.7);
                if (cur_exposure < EXPOSURE_MIN) cur_exposure = EXPOSURE_MIN;
                if (cur_exposure == EXPOSURE_MIN && cur_gain > GAIN_MIN) cur_gain--;
                set_sensor_controls(subdev_path, cur_exposure, cur_gain);
                brightness = 1.0f;
            }
            last_ae_time = now;
        }

        /* Output */
        size_t frame_bytes = (size_t)(OUT_W * OUT_H * 2);
        ssize_t wr = write(out_fd, yuyv_buf, frame_bytes);
        if (wr < 0 && errno != EAGAIN) { perror("write output"); break; }

        if (xioctl(cap_fd, VIDIOC_QBUF, &buf) < 0) { perror("VIDIOC_QBUF"); break; }

        output_count++;
        if (output_count % 150 == 0) {
            printf("[gc2607_isp] %d frames out | WB: R=%.2f B=%.2f | bright=%.2f | exp=%d gain=%d\n",
                   output_count, (double)wb_r, (double)wb_b, (double)brightness,
                   cur_exposure, cur_gain);
        }
    }

    printf("[gc2607_isp] Shutdown (%d sensor frames, %d output frames)\n",
           frame_count, output_count);

    enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    xioctl(cap_fd, VIDIOC_STREAMOFF, &t);
    for (int i = 0; i < n_bufs; i++) munmap(bufs[i].start, bufs[i].length);
    close(cap_fd);
    close(out_fd);
    return 0;
}
