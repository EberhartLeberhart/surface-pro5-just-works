/*
 * surface-kamera-daemon v9
 * Basis: v6 (stabil, selbstlernend)
 * Neu: Switcher Fenster wird gestartet NACHDEM Pipeline 2s stabil laeuft
 * Kamerawechsel via /tmp/surface-kamera-cmd
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <syslog.h>

#define VIDEO_DEVICE     "/dev/video20"
#define CMD_FILE         "/tmp/surface-kamera-cmd"
#define SWITCHER         "/home/sd/.local/bin/surface-kamera-switcher.py"
#define POLL_MS          500
#define STOP_DELAY_SEC   5
#define CONFIG_DIR       "/etc/surface-kamera"
#define CONFIG_FILE      "/etc/surface-kamera/known-apps.conf"
#define MAX_APPS         64
#define MAX_NAME         64

/* Frontkamera (OV5693) = camera-name=1 */
static const char *GST_FRONT[] = {
    "gst-launch-1.0","libcamerasrc","camera-name=1",
    "!","video/x-raw,width=1280,height=720,framerate=30/1,format=NV12",
    "!","queue","max-size-buffers=8","leaky=downstream",
    "!","videoconvert","!","video/x-raw,format=YUY2",
    "!","v4l2sink","device=/dev/video20","sync=false",NULL
};

/* Rueckkamera (OV8865) = camera-name=0 */
static const char *GST_REAR[] = {
    "gst-launch-1.0","libcamerasrc","camera-name=0",
    "!","video/x-raw,width=1280,height=720,framerate=30/1,format=NV12",
    "!","queue","max-size-buffers=8","leaky=downstream",
    "!","videoconvert","!","video/x-raw,format=YUY2",
    "!","v4l2sink","device=/dev/video20","sync=false",NULL
};

static const char *ALWAYS_IGNORED[] = {
    "wireplumber","pipewire","pipewire-pulse","gst-launch-1.0",
    "surface-kamera","python3",NULL
};

static char known_apps[MAX_APPS][MAX_NAME];
static int  n_known      = 0;
static pid_t pipeline_pid = -1;
static pid_t switcher_pid = -1;
static int   aktive_kamera = 0; /* 0=front 1=rear */
static time_t idle_since  = 0;
static volatile int running = 1;

static void sig_handler(int sig) { (void)sig; running = 0; }

static void config_load(void) {
    FILE *f = fopen(CONFIG_FILE, "r");
    if (!f) return;
    char line[MAX_NAME];
    while (fgets(line, sizeof(line), f) && n_known < MAX_APPS) {
        line[strcspn(line, "\n#")] = 0;
        if (strlen(line) > 0)
            strncpy(known_apps[n_known++], line, MAX_NAME-1);
    }
    fclose(f);
    syslog(LOG_INFO, "Kamera: %d bekannte Apps geladen", n_known);
}

static void config_add_app(const char *name) {
    for (int i = 0; i < n_known; i++)
        if (strcmp(known_apps[i], name) == 0) return;
    if (n_known >= MAX_APPS) return;
    strncpy(known_apps[n_known++], name, MAX_NAME-1);
    syslog(LOG_INFO, "Kamera: Neue App gelernt: %s", name);
    mkdir(CONFIG_DIR, 0755);
    FILE *f = fopen(CONFIG_FILE, "a");
    if (f) { fprintf(f, "%s\n", name); fclose(f); }
}

static void pipeline_stop(void) {
    if (pipeline_pid <= 0) return;
    syslog(LOG_INFO, "Kamera: Stoppe Pipeline...");
    kill(pipeline_pid, SIGTERM);
    for (int i = 0; i < 30; i++) {
        usleep(100000);
        if (waitpid(pipeline_pid, NULL, WNOHANG) == pipeline_pid) {
            pipeline_pid = -1; return;
        }
    }
    kill(pipeline_pid, SIGKILL);
    waitpid(pipeline_pid, NULL, 0);
    pipeline_pid = -1;
}

static void pipeline_start(int kamera) {
    pipeline_stop();
    aktive_kamera = kamera;
    const char **argv = (kamera == 0) ? GST_FRONT : GST_REAR;
    const char *name  = (kamera == 0) ? "Front" : "Rear";
    pid_t pid = fork();
    if (pid < 0) { syslog(LOG_ERR, "fork: %s", strerror(errno)); return; }
    if (pid == 0) {
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, 1); dup2(dn, 2); close(dn); }
        execvp(argv[0], (char *const *)argv);
        _exit(1);
    }
    pipeline_pid = pid;
    syslog(LOG_INFO, "Kamera: Pipeline %s PID=%d", name, (int)pid);
}

static void switcher_stop(void) {
    if (switcher_pid <= 0) return;
    kill(switcher_pid, SIGTERM);
    waitpid(switcher_pid, NULL, WNOHANG);
    switcher_pid = -1;
    unlink(CMD_FILE);
}

static void switcher_start(void) {
    if (switcher_pid > 0) return;
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        setenv("DISPLAY", ":0", 1);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, 2); close(dn); }
        execlp("python3", "python3", SWITCHER,
               aktive_kamera == 0 ? "front" : "rear", NULL);
        _exit(1);
    }
    switcher_pid = pid;
    syslog(LOG_INFO, "Kamera: Switcher PID=%d", (int)pid);
}

/* -1=nichts, 0=front, 1=rear, 2=restart */
static int read_cmd(void) {
    FILE *f = fopen(CMD_FILE, "r");
    if (!f) return -1;
    char buf[32] = {0};
    fgets(buf, sizeof(buf), f);
    fclose(f);
    unlink(CMD_FILE);
    if (strncmp(buf, "rear", 4) == 0) return 1;
    if (strncmp(buf, "front", 5) == 0) return 0;
    if (strncmp(buf, "restart", 7) == 0) return 2;
    return -1;
}

static void reap(void) {
    int st; pid_t p;
    while ((p = waitpid(-1, &st, WNOHANG)) > 0) {
        if (p == pipeline_pid) {
            syslog(LOG_WARNING, "Kamera: Pipeline unerwartet beendet");
            pipeline_pid = -1;
        }
        if (p == switcher_pid) switcher_pid = -1;
    }
}

static int get_comm(long pid, char *name, size_t len) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%ld/comm", pid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    if (fgets(name, len, f)) name[strcspn(name, "\n")] = 0;
    fclose(f);
    return strlen(name) > 0;
}

static int is_always_ignored(const char *name) {
    for (int i = 0; ALWAYS_IGNORED[i]; i++)
        if (strncmp(name, ALWAYS_IGNORED[i], strlen(ALWAYS_IGNORED[i])) == 0)
            return 1;
    return 0;
}

static int known_app_running(void) {
    DIR *proc = opendir("/proc");
    if (!proc) return 0;
    struct dirent *pe; int found = 0;
    while (!found && (pe = readdir(proc)) != NULL) {
        char *end; long pid = strtol(pe->d_name, &end, 10);
        if (*end != '\0') continue;
        char name[MAX_NAME] = {0};
        if (!get_comm(pid, name, sizeof(name))) continue;
        for (int i = 0; i < n_known; i++)
            if (strcmp(name, known_apps[i]) == 0) { found = 1; break; }
    }
    closedir(proc);
    return found;
}

static int foreign_user_exists(char *found_name, size_t name_len) {
    struct stat target;
    if (stat(VIDEO_DEVICE, &target) != 0) return 0;
    DIR *proc = opendir("/proc");
    if (!proc) return 0;
    struct dirent *pe; int found = 0;
    while (!found && (pe = readdir(proc)) != NULL) {
        char *end; long pid = strtol(pe->d_name, &end, 10);
        if (*end != '\0') continue;
        if ((pid_t)pid == pipeline_pid || (pid_t)pid == getpid() ||
            (pid_t)pid == switcher_pid) continue;
        char name[MAX_NAME] = {0};
        if (!get_comm(pid, name, sizeof(name))) continue;
        if (is_always_ignored(name)) continue;
        char fddir[64];
        snprintf(fddir, sizeof(fddir), "/proc/%ld/fd", pid);
        DIR *fds = opendir(fddir);
        if (!fds) continue;
        struct dirent *fe;
        while ((fe = readdir(fds)) != NULL) {
            if (fe->d_name[0] == '.') continue;
            char fdpath[256];
            snprintf(fdpath, sizeof(fdpath), "/proc/%ld/fd/%s", pid, fe->d_name);
            struct stat st;
            if (stat(fdpath, &st) == 0 && st.st_rdev == target.st_rdev
                && S_ISCHR(st.st_mode)) {
                syslog(LOG_INFO, "Kamera: genutzt von '%s' (PID=%ld)", name, pid);
                if (found_name) strncpy(found_name, name, name_len-1);
                found = 1; break;
            }
        }
        closedir(fds);
    }
    closedir(proc);
    return found;
}

int main(void) {
    openlog("surface-kamera", LOG_PID|LOG_CONS, LOG_DAEMON);
    syslog(LOG_INFO, "surface-kamera-daemon v9 gestartet");
    signal(SIGTERM, sig_handler);
    signal(SIGINT,  sig_handler);
    config_load();

    while (running && access(VIDEO_DEVICE, F_OK) != 0) {
        syslog(LOG_INFO, "Warte auf %s...", VIDEO_DEVICE);
        sleep(2);
    }
    syslog(LOG_INFO, "Kamera: Bereit. %d bekannte Apps.", n_known);

    time_t pipeline_stable_since = 0;

    while (running) {
        reap();

        /* === 1. Kamerawechsel/Neustart via CMD Datei === */
        int cmd = read_cmd();
        if (cmd == 0 && aktive_kamera != 0) {
            syslog(LOG_INFO, "Kamera: Wechsel zu Frontkamera");
            pipeline_start(0);
            pipeline_stable_since = 0;
        } else if (cmd == 1 && aktive_kamera != 1) {
            syslog(LOG_INFO, "Kamera: Wechsel zu Rueckkamera");
            pipeline_start(1);
            pipeline_stable_since = 0;
        } else if (cmd == 2) {
            syslog(LOG_INFO, "Kamera: Neustart Pipeline...");
            pipeline_start(aktive_kamera);
            pipeline_stable_since = 0;
        }

        /* === 2. Bekannte App erkannt -> Pipeline starten === */
        int known_running = known_app_running();
        if (known_running && pipeline_pid <= 0) {
            syslog(LOG_INFO, "Kamera: Bekannte App erkannt, starte Pipeline...");
            pipeline_start(0); /* immer mit Front starten */
            pipeline_stable_since = 0;
            idle_since = 0;
        }

        /* === 3. Stabilitaets-Timer: nach 2s -> Switcher starten === */
        if (pipeline_pid > 0) {
            if (pipeline_stable_since == 0)
                pipeline_stable_since = time(NULL);
            else if (switcher_pid <= 0 &&
                     (time(NULL) - pipeline_stable_since) >= 2) {
                syslog(LOG_INFO, "Kamera: Pipeline stabil, starte Switcher...");
                switcher_start();
            }
        } else {
            pipeline_stable_since = 0;
        }

        /* === 4. Fremde App lernen === */
        char user_name[MAX_NAME] = {0};
        int in_use = foreign_user_exists(user_name, sizeof(user_name));
        if (in_use && strlen(user_name) > 0 && !is_always_ignored(user_name))
            config_add_app(user_name);

        /* === 5. Kein Consumer -> stoppen === */
        if (!known_running && !in_use) {
            if (pipeline_pid > 0 || switcher_pid > 0) {
                if (idle_since == 0) {
                    idle_since = time(NULL);
                    syslog(LOG_INFO, "Kamera: Kein Consumer, warte %ds...", STOP_DELAY_SEC);
                } else if ((time(NULL) - idle_since) >= STOP_DELAY_SEC) {
                    pipeline_stop();
                    switcher_stop();
                    aktive_kamera = 0;
                    pipeline_stable_since = 0;
                    idle_since = 0;
                }
            }
        } else {
            idle_since = 0;
        }

        usleep(POLL_MS * 1000);
    }

    pipeline_stop();
    switcher_stop();
    closelog();
    return 0;
}
