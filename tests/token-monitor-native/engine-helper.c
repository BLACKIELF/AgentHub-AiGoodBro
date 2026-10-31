#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/stat.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (getenv("TOKEN_MONITOR_FIXTURE_SENTINEL")) return 5;
    char cwd[4096], home[4096];
    if (!getcwd(cwd, sizeof(cwd)) || !getenv("HOME") || !realpath(getenv("HOME"), home) || strcmp(cwd, home)) return 6;
    const char *mode = strrchr(argv[1], '/'); mode = mode ? mode + 1 : argv[1];
    if (!strcmp(mode, "timeout") || !strcmp(mode, "cancel")) { for (;;) pause(); }
    if (!strcmp(mode, "early")) return 0;
    if (!strcmp(mode, "overflow") || !strcmp(mode, "stderr")) {
        char b[16384]; memset(b, 'x', sizeof(b));
        for (int i = 0; i < 2200; i++) write(!strcmp(mode, "stderr") ? 2 : 1, b, sizeof(b));
        return 0;
    }
    if (!strcmp(mode, "held") || !strcmp(mode, "closed")) {
        pid_t pid = fork();
        if (pid == 0) {
            if (!strcmp(mode, "closed")) { close(0); close(1); close(2); }
            for (;;) pause();
        }
        char path[4096]; snprintf(path, sizeof(path), "%s.pid", argv[1]);
        FILE *f = fopen(path, "w"); if (f) { fprintf(f, "%d", pid); fclose(f); }
    }
    int fd = open(argv[1], O_RDONLY); char b[4096]; ssize_t n;
    // Deliberately write before draining stdin: verifies simultaneous native I/O.
    while ((n = read(fd, b, sizeof(b))) > 0) { write(1, b, n); }
    close(fd);
    while (read(0, b, sizeof(b)) > 0) {}
    if (!strcmp(mode, "nonzero")) return 3;
    return 0;
}
