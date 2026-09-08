// Minimal nonshipping peer for the signed application-launch handoff qualification harness.
// It implements the daemon side of the one-shot protocol without importing Dory sources. The
// harness signs this executable under different identities to prove that the production runner's
// live Security.framework check gates token and descriptor transfer.

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libkern/OSByteOrder.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

enum {
  token_bytes = 32,
  token_hex_bytes = token_bytes * 2,
  descriptor_marker = 0xd4,
  acknowledgement = 0xa7,
};

static int write_all(int descriptor, const void *source, size_t count) {
  const unsigned char *cursor = source;
  while (count > 0) {
    ssize_t written = write(descriptor, cursor, count);
    if (written > 0) {
      cursor += written;
      count -= (size_t)written;
      continue;
    }
    if (written < 0 && errno == EINTR) {
      continue;
    }
    return -1;
  }
  return 0;
}

static int read_all(int descriptor, void *destination, size_t count) {
  unsigned char *cursor = destination;
  while (count > 0) {
    ssize_t read_count = read(descriptor, cursor, count);
    if (read_count > 0) {
      cursor += read_count;
      count -= (size_t)read_count;
      continue;
    }
    if (read_count < 0 && errno == EINTR) {
      continue;
    }
    return -1;
  }
  return 0;
}

static int send_frame(int descriptor, const char *payload) {
  size_t payload_bytes = strlen(payload);
  if (payload_bytes > UINT32_MAX) {
    return -1;
  }
  uint32_t length = OSSwapHostToBigInt32((uint32_t)payload_bytes);
  return write_all(descriptor, &length, sizeof(length)) == 0
      && write_all(descriptor, payload, payload_bytes) == 0 ? 0 : -1;
}

static int send_descriptor(int socket, int authority) {
  unsigned char control[CMSG_SPACE(sizeof(authority))];
  memset(control, 0, sizeof(control));
  unsigned char marker = descriptor_marker;
  struct iovec vector = {.iov_base = &marker, .iov_len = sizeof(marker)};
  struct msghdr message = {
    .msg_iov = &vector,
    .msg_iovlen = 1,
    .msg_control = control,
    .msg_controllen = sizeof(control),
  };
  struct cmsghdr *header = CMSG_FIRSTHDR(&message);
  header->cmsg_len = CMSG_LEN(sizeof(authority));
  header->cmsg_level = SOL_SOCKET;
  header->cmsg_type = SCM_RIGHTS;
  memcpy(CMSG_DATA(header), &authority, sizeof(authority));
  while (1) {
    ssize_t sent = sendmsg(socket, &message, 0);
    if (sent == 1) {
      return 0;
    }
    if (sent < 0 && errno == EINTR) {
      continue;
    }
    return -1;
  }
}

static void cleanup(const char *path, int listener) {
  if (listener >= 0) {
    close(listener);
  }
  if (path != NULL) {
    unlink(path);
  }
}

int main(int argc, char **argv) {
  const char *directory = argc == 2 ? argv[1] : NULL;
  struct stat directory_status;
  char path[PATH_MAX] = "";
  char token[token_hex_bytes + 1];
  const char digits[] = "0123456789abcdef";
  unsigned char random[token_bytes];
  int listener = -1;
  int connection = -1;
  int authority = -1;
  int result = 1;

  signal(SIGPIPE, SIG_IGN);
  alarm(20);
  if (directory == NULL || directory[0] != '/' || lstat(directory, &directory_status) != 0
      || !S_ISDIR(directory_status.st_mode) || directory_status.st_uid != geteuid()
      || (directory_status.st_mode & 0777) != 0700
      || snprintf(path, sizeof(path), "%s/h.sock", directory) >= (int)sizeof(path)) {
    perror("prepare handoff directory");
    goto finish;
  }
  arc4random_buf(random, sizeof(random));
  for (size_t index = 0; index < sizeof(random); index += 1) {
    token[index * 2] = digits[random[index] >> 4];
    token[index * 2 + 1] = digits[random[index] & 15];
  }
  token[token_hex_bytes] = '\0';

  listener = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  if (listener < 0 || strlen(path) >= sizeof(address.sun_path)) {
    perror("create handoff socket");
    goto finish;
  }
  memcpy(address.sun_path, path, strlen(path) + 1);
  if (bind(listener, (const struct sockaddr *)&address, sizeof(address)) != 0
      || chmod(path, 0600) != 0 || listen(listener, 1) != 0) {
    perror("listen handoff socket");
    goto finish;
  }
  printf("READY %s %s\n", path, token);
  fflush(stdout);

  connection = accept(listener, NULL, NULL);
  if (connection < 0) {
    perror("accept handoff peer");
    goto finish;
  }
  uint32_t network_length = 0;
  if (read_all(connection, &network_length, sizeof(network_length)) != 0) {
    printf("RESULT token=0 descriptor=0 acknowledgement=0\n");
    result = 0;
    goto finish;
  }
  uint32_t token_length = OSSwapBigToHostInt32(network_length);
  char received[token_hex_bytes + 1];
  if (token_length != token_hex_bytes || read_all(connection, received, token_length) != 0) {
    fprintf(stderr, "invalid token frame\n");
    goto finish;
  }
  received[token_hex_bytes] = '\0';
  if (memcmp(token, received, token_hex_bytes) != 0) {
    fprintf(stderr, "token mismatch\n");
    goto finish;
  }
  if (send_frame(connection, "{\"schemaVersion\":1,\"targetDescriptors\":[900]}") != 0) {
    perror("send descriptor manifest");
    goto finish;
  }
  authority = open("/dev/null", O_RDONLY | O_CLOEXEC);
  if (authority < 0 || send_descriptor(connection, authority) != 0) {
    perror("send granted descriptor");
    goto finish;
  }
  unsigned char received_acknowledgement = 0;
  if (read_all(connection, &received_acknowledgement, 1) != 0) {
    perror("read handoff acknowledgement");
    goto finish;
  }
  printf("RESULT token=1 descriptor=1 acknowledgement=%d\n",
         received_acknowledgement == acknowledgement);
  result = received_acknowledgement == acknowledgement ? 0 : 1;

finish:
  if (authority >= 0) {
    close(authority);
  }
  if (connection >= 0) {
    close(connection);
  }
  cleanup(path[0] ? path : NULL, listener);
  return result;
}
