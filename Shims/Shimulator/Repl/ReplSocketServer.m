/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "ReplSocketServer.h"

#import <dlfcn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

// The single accepted client connection's fd, stashed for that connection's
// lifetime so injected code can issue nested host commands (see
// FBReplInvokeHostCommand). Safe as a file-scoped static: there is exactly one
// connection and the protocol is single-threaded and lockstep.
static int gClientFd = -1;

// Whether the host process outlives a single session (keepListening:YES, the app
// context). Read via FBReplHostOutlivesSession by injected code deciding whether a
// lost connection should end the process or just reset. Set when the server starts.
static BOOL gHostOutlivesSession = NO;

// The next run index for compiled dylibs, bumped once per executed command.
// Persists for the process lifetime -- including across client reconnects for the
// `app` context.
static int gRunIndex = 0;

// A stable identifier for this REPL host process, generated once and persisted for
// the process lifetime -- including across client reconnects for the `app` context
// (like gRunIndex). The driver keys its session report on this: reconnecting to a
// still-running app sees the same id and appends to the report, while a relaunch is
// a new process with a new id that starts the report fresh.
static NSString *gSessionID = nil;

// MARK: - Socket Setup

static int CreateSocketAtPath(NSString *socketPath)
{
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return -1;
  }

  unlink(socketPath.fileSystemRepresentation);

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, socketPath.fileSystemRepresentation, sizeof(addr.sun_path));

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0
      || listen(fd, 1) < 0) {
    close(fd);
    return -1;
  }

  return fd;
}

// MARK: - Framing (see ReplSocketServer.h)

static BOOL ReadFully(int fd, void *buffer, size_t count)
{
  size_t total = 0;
  while (total < count) {
    ssize_t n = read(fd, (char *)buffer + total, count - total);
    if (n <= 0) {
      return NO;
    }
    total += (size_t)n;
  }
  return YES;
}

static BOOL WriteFully(int fd, const void *buffer, size_t count)
{
  size_t total = 0;
  while (total < count) {
    // Use send() with MSG_NOSIGNAL rather than write() so a write to a client
    // that has hung up without completing the protocol (e.g. the reattach
    // liveness probe connects then closes without reading) fails with EPIPE
    // instead of raising SIGPIPE and terminating the host app.
    ssize_t n = send(fd, (const char *)buffer + total, count - total, MSG_NOSIGNAL);
    if (n <= 0) {
      return NO;
    }
    total += (size_t)n;
  }
  return YES;
}

// Reads one frame's payload bytes, or nil on EOF/error (a closed connection).
static NSData *ReadFrame(int fd)
{
  uint8_t header[4];
  if (!ReadFully(fd, header, sizeof(header))) {
    return nil;
  }
  uint32_t length = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | (uint32_t)header[3];
  NSMutableData *payload = [NSMutableData dataWithLength:length];
  if (length > 0 && !ReadFully(fd, payload.mutableBytes, length)) {
    return nil;
  }
  return payload;
}

static BOOL WriteFrame(int fd, NSData *payload)
{
  uint32_t length = (uint32_t)payload.length;
  uint8_t header[4] = {
    (uint8_t)((length >> 24) & 0xFF),
    (uint8_t)((length >> 16) & 0xFF),
    (uint8_t)((length >> 8) & 0xFF),
    (uint8_t)(length & 0xFF),
  };
  if (!WriteFully(fd, header, sizeof(header))) {
    return NO;
  }
  return WriteFully(fd, payload.bytes, payload.length);
}

static NSDictionary *DecodeMessage(NSData *frame)
{
  if (!frame) {
    return nil;
  }
  id message = [NSPropertyListSerialization propertyListWithData:frame options:0 format:NULL error:NULL];
  return [message isKindOfClass:[NSDictionary class]] ? message : nil;
}

static NSDictionary *ReadMessage(int fd)
{
  return DecodeMessage(ReadFrame(fd));
}

static void WriteMessage(NSDictionary *message, int fd)
{
  NSData *payload = [NSPropertyListSerialization dataWithPropertyList:message format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
  if (payload) {
    WriteFrame(fd, payload);
  }
}

// MARK: - Command Processing

// A `dlerror()` message, or the fallback when there is none or it is not UTF-8.
static NSString *ReplErrorString(const char *message, NSString *fallback)
{
  NSString *string = message == NULL ? nil : [NSString stringWithUTF8String:message];
  return string ?: fallback;
}

static NSDictionary *ProcessCommand(NSDictionary *command)
{
  NSString *dylibPath = command[@"dylib"];
  NSString *symbol = command[@"symbol"];
  if (!dylibPath || !symbol) {
    return @{@"success" : @NO, @"error" : @"Missing dylib or symbol"};
  }

  void *handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW);
  if (!handle) {
    const char *err = dlerror();
    return @{@"success" : @NO, @"error" : ReplErrorString(err, @"dlopen failed")};
  }

  const char *(*func)(void) = (const char *(*)(void))dlsym(handle, symbol.UTF8String);
  if (!func) {
    const char *err = dlerror();
    return @{@"success" : @NO, @"error" : ReplErrorString(err, @"symbol not found")};
  }

  const char *cResult = func();
  NSString *resultStr = cResult ? [NSString stringWithUTF8String:cResult] : @"";
  free((void *)cResult);

  return @{@"success" : @YES, @"result" : resultStr};
}

// MARK: - Entry Point

int FBReplServeSocket(NSString *socketPath, NSArray<NSString *> *generatedInterfaces, BOOL keepListening)
{
  gHostOutlivesSession = keepListening;

  if (gSessionID == nil) {
    gSessionID = [[[NSUUID UUID] UUIDString] copy];
  }

  if (socketPath.length == 0) {
    return 0;
  }

  int serverFd = CreateSocketAtPath(socketPath);
  if (serverFd < 0) {
    return 1;
  }

  // keepListening (app context): re-accept after each client disconnects instead of
  // returning.
  BOOL listening = YES;
  while (listening) {
    int clientFd = accept(serverFd, NULL, NULL);
    if (clientFd < 0) {
      break;
    }
    gClientFd = clientFd;
    WriteMessage(@{@"type" : @"greeting", @"interfaces" : generatedInterfaces ?: @[], @"nextRunIndex" : @(gRunIndex), @"sessionID" : gSessionID ?: @""}, clientFd);
    BOOL connected = YES;
    while (connected) {
      @autoreleasepool {
        NSDictionary *command = ReadMessage(clientFd);
        if (!command) {
          connected = NO;
        } else {
          NSMutableDictionary *response = [ProcessCommand(command) mutableCopy];
          response[@"type"] = @"result";
          gRunIndex++;
          response[@"nextRunIndex"] = @(gRunIndex);
          WriteMessage(response, clientFd);
          [response release];
        }
      }
    }
    gClientFd = -1;
    close(clientFd);
    listening = keepListening;
  }

  close(serverFd);
  unlink(socketPath.fileSystemRepresentation);
  return 0;
}

// MARK: - Host Commands

// `used` + default visibility: nothing in the host links against this symbol
// statically -- it is resolved only via dlsym() from injected REPL dylibs -- so
// without these attributes the linker dead-strips it out of the bridge/shim and
// the lookup fails.
__attribute__((used, visibility("default")))
void *FBReplInvokeHostCommand(const void *commandBytes, int commandLength, int *outLength)
{
  int fd = gClientFd;
  if (fd < 0) {
    return NULL;
  }

  @autoreleasepool {
    NSData *commandData = commandBytes != NULL ? [NSData dataWithBytes:commandBytes length:(NSUInteger)commandLength] : [NSData data];
    WriteMessage(@{@"type" : @"host_command", @"command" : commandData}, fd);
  }

  // Read frames until the matching host_result. Because host commands are
  // strictly nested inside an executing command, nothing else is on the socket.
  // The host_result frame's raw bytes are returned verbatim (malloc'd) for the
  // caller to decode.
  void *result = NULL;
  int resultLength = 0;
  BOOL connected = YES;
  while (connected && result == NULL) {
    @autoreleasepool {
      NSData *frame = ReadFrame(fd);
      if (!frame) {
        connected = NO;
      } else if ([DecodeMessage(frame)[@"type"] isEqualToString:@"host_result"]) {
        resultLength = (int)frame.length;
        result = malloc(frame.length);
        memcpy(result, frame.bytes, frame.length);
      }
    }
  }

  if (result != NULL && outLength != NULL) {
    *outLength = resultLength;
  }
  return result;
}

// Resolved via dlsym from injected REPL code (like FBReplInvokeHostCommand), so it
// needs the same used + default-visibility treatment to survive dead-stripping.
__attribute__((used, visibility("default")))
BOOL FBReplHostOutlivesSession(void)
{
  return gHostOutlivesSession;
}
