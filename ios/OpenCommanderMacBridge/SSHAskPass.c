// One-shot OpenSSH password bridge. Secrets travel only through a private local socket.
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

static void wipe(void *memory, size_t length) {
    volatile unsigned char *bytes = memory;
    while (length--) *bytes++ = 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    char prompt[1024];
    size_t length = strlen(argv[1]);
    if (length >= sizeof(prompt)) return 1;
    for (size_t i = 0; i <= length; i++) prompt[i] = (char)tolower((unsigned char)argv[1][i]);
    if (!strstr(prompt, "password")) return 1; // never answer host trust or unrelated prompts
    const char *path = getenv("OPENCOMMANDER_ASKPASS_SOCKET");
    struct sockaddr_un address = {0};
    struct stat info;
    if (!path || strlen(path) >= sizeof(address.sun_path) || lstat(path, &info) != 0 ||
        !S_ISSOCK(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 077) != 0) return 1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 1;
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return 1; }
    uid_t uid; gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0 || uid != getuid()) { close(fd); return 1; }
    struct timeval timeout = {15, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    char buffer[8194]; size_t used = 0; ssize_t count;
    while (used < sizeof(buffer) && (count = read(fd, buffer + used, sizeof(buffer) - used)) > 0) used += (size_t)count;
    close(fd);
    if (!used || used >= sizeof(buffer) || buffer[used - 1] != '\n') { wipe(buffer, sizeof(buffer)); return 1; }
    size_t offset = 0;
    while (offset < used) {
        count = write(STDOUT_FILENO, buffer + offset, used - offset);
        if (count <= 0) { wipe(buffer, sizeof(buffer)); return 1; }
        offset += (size_t)count;
    }
    wipe(buffer, sizeof(buffer)); return 0;
}
