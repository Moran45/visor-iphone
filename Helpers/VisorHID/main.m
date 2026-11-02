// VisorHID: la Mac se presenta ante el iPhone como un puntero Bluetooth absoluto (HID clásico) y el
// iPhone lo usa con AssistiveTouch. Así los toques y arrastres llegan en vivo, sin pasar por XCTest.
//
// El transporte sigue el de open-phone (MIT, https://github.com/Array-Ventures/open-phone, native/hid.m):
// usa clases privadas de CoreBluetooth (CBClassicManager/CBClassicPeer), así que una actualización de
// macOS puede romperlo.
//
// Protocolo: líneas JSON por stdin/stdout (`VisorHID --stdio`, así lo lanza Visor iPhone) o por un socket
// Unix (`VisorHID <ruta>`). Un solo cliente; al cerrarse, se retira el servicio HID y el proceso termina.
//   {"cmd":"start","name":"Carlos iphone"}   o "address":"A8:81:7E:56:CB:A7"; con "passive":true espera
//                                            a que el iPhone se conecte (necesario la primera vez)
//   {"cmd":"pointer","x":0-32767,"y":0-32767,"buttons":0|1}   sin respuesta; los movimientos se agrupan
//   {"cmd":"scroll","dy":-127-127,"dx":-127-127}   rueda en la última posición del puntero
//   {"cmd":"status"}  {"cmd":"stop"}
// Eventos: ready, error, waiting, channel_open, channel_closed, peer_connected, peer_disconnected.
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <fcntl.h>
#import <signal.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

@interface VHClassicPeer : NSObject
@property(readonly) NSString *addressString;
@property(readonly) NSInteger state;
- (void)openL2CAPChannel:(uint16_t)psm;
- (void)closeL2CAPChannel:(uint16_t)psm;
- (void)setConnectL2CAPCallback:(void (^)(CBL2CAPChannel *, NSInteger))block;
- (void)setDisconnectL2CAPCallback:(void (^)(CBL2CAPChannel *, NSInteger))block;
- (void)handleL2CAPChannelOpened:(NSDictionary *)args;
- (void)handleL2CAPChannelClosed:(NSDictionary *)args;
@end

@interface VHClassicManager : NSObject
@property(readonly) NSInteger state;
- (instancetype)initWithQueue:(dispatch_queue_t)queue options:(NSDictionary *)options;
- (void)setTccApproved:(BOOL)value;
- (void)doneWithTCC;
- (void)setBTConnectable:(BOOL)value;
- (void)setBTDiscoverable:(BOOL)value;
- (uint32_t)addServiceWithData:(NSData *)data;
- (void)removeServiceHandle:(uint32_t)handle;
- (VHClassicPeer *)retrievePeerWithAddress:(NSString *)address;
- (void)connectPeer:(VHClassicPeer *)peer options:(NSDictionary *)options;
- (void)setConnectCallback:(void (^)(VHClassicPeer *, NSInteger))block;
- (void)setDisconnectCallback:(void (^)(VHClassicPeer *, NSInteger))block;
@end

@interface CBL2CAPChannel (VHPrivate)
@property(readonly) VHClassicPeer *peer;
@property(readonly) int socketFD;
@property(readonly) uint16_t outgoingMTU;
@end

// Registro SDP (puntero absoluto con rueda, ID 2, + teclado, ID 1) en la codificación del daemon de CoreBluetooth.
// Generado con Scripts/hid_sdp.py.
static const uint8_t kSDPRecord[] = {
#include "sdp_record.inc"
};

static const uint16_t kControlPSM = 0x11;
static const uint16_t kInterruptPSM = 0x13;

static int clientFD = -1;
static NSLock *emitLock;

static void emit(NSDictionary *value) {
  NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] mutableCopy];
  [data appendBytes:"\n" length:1];
  [emitLock lock];
  if (clientFD >= 0) write(clientFD, data.bytes, data.length);
  [emitLock unlock];
}

static void event(NSString *name, NSDictionary *fields) {
  NSMutableDictionary *d = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
  d[@"event"] = name;
  emit(d);
}

/// CoreBluetooth usa un socket local; el mensaje de control vacío es el que espera su transporte.
static ssize_t packetWrite(int fd, NSData *packet) {
  struct iovec io = {(void *)packet.bytes, packet.length};
  struct cmsghdr control = {.cmsg_len = sizeof(struct cmsghdr), .cmsg_level = SOL_SOCKET, .cmsg_type = SCM_RIGHTS};
  struct msghdr msg = {0};
  msg.msg_iov = &io;
  msg.msg_iovlen = 1;
  msg.msg_control = &control;
  msg.msg_controllen = sizeof(control);
  return sendmsg(fd, &msg, MSG_DONTWAIT);
}

@interface Controller : NSObject <CBCentralManagerDelegate>
@property(nonatomic, strong) CBCentralManager *permission;
@property(nonatomic, strong) VHClassicManager *manager;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, copy) NSString *address;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, CBL2CAPChannel *> *channels;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, dispatch_source_t> *readers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *lastReports;
@property uint32_t serviceHandle;
@property BOOL starting;
@property(nonatomic, strong) dispatch_queue_t sendQueue;
/// Reportes que no se pueden perder, cada uno con la hora mínima de envío ({report, notBefore}).
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *mustSend;
@property(nonatomic, strong) NSData *latestMove;
@property BOOL retryScheduled;
/// Tras presionar, los movimientos esperan hasta esta hora (CFAbsoluteTime).
@property double moveNotBefore;
@property int lastX;
@property int lastY;
@property uint32_t lastButtons;
- (void)opened:(CBL2CAPChannel *)channel status:(NSInteger)status;
- (void)closed:(CBL2CAPChannel *)channel status:(NSInteger)status;
@end

static Controller *controller;
static IMP originalPeerMessage;

// Los canales HID entrantes no tienen callbacks en la API pública: se interceptan solo los PSM HID.
static void peerMessage(id peer, SEL selector, int message, NSDictionary *args) {
  uint16_t psm = [args[@"kCBMsgArgPSM"] unsignedShortValue];
  if (controller && (psm == kControlPSM || psm == kInterruptPSM)) {
    NSMutableDictionary *detail = [NSMutableDictionary dictionary];
    for (NSString *key in args) detail[key] = [args[key] description];
    event(@"peer_message", @{@"message" : @(message), @"psm" : @(psm), @"args" : detail});
    if (message == 27 && [args[@"kCBMsgArgResult"] intValue] == 0) {
      [(VHClassicPeer *)peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, NSInteger status) { [controller opened:ch status:status]; }];
      [(VHClassicPeer *)peer setDisconnectL2CAPCallback:^(CBL2CAPChannel *ch, NSInteger status) { [controller closed:ch status:status]; }];
      [(VHClassicPeer *)peer handleL2CAPChannelOpened:args];
      return;
    }
    if (message == 27) event(@"channel_failed", @{@"psm" : @(psm), @"result" : args[@"kCBMsgArgResult"] ?: @0});
    if (message == 28) {
      [(VHClassicPeer *)peer setDisconnectL2CAPCallback:^(CBL2CAPChannel *ch, NSInteger status) { [controller closed:ch status:status]; }];
      [(VHClassicPeer *)peer handleL2CAPChannelClosed:args];
      return;
    }
  }
  ((void (*)(id, SEL, int, id))originalPeerMessage)(peer, selector, message, args);
}

@implementation Controller

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("visor.hid", DISPATCH_QUEUE_SERIAL);
    _lock = [NSLock new];
    _channels = [NSMutableDictionary dictionary];
    _readers = [NSMutableDictionary dictionary];
    _lastReports = [NSMutableDictionary dictionary];
    _sendQueue = dispatch_queue_create("visor.hid.send", DISPATCH_QUEUE_SERIAL);
    _mustSend = [NSMutableArray array];
  }
  return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  event(@"bluetooth", @{@"state" : @(central.state), @"authorization" : @(CBManager.authorization)});
}

- (BOOL)connected {
  [self.lock lock];
  BOOL ok = self.channels[@(kControlPSM)] != nil && self.channels[@(kInterruptPSM)] != nil;
  [self.lock unlock];
  return ok;
}

/// Permiso de Bluetooth → servicio HID publicado → iPhone conectado → canales de control e interrupción.
/// passive: publica el servicio y espera a que el iPhone abra los canales (como un mouse Bluetooth normal).
- (void)startWithAddress:(NSString *)address name:(NSString *)name passive:(BOOL)passive {
  if (self.starting) return;
  self.starting = YES;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self startPeer:address name:name passive:passive];
  });
}

/// Dirección Bluetooth del iPhone emparejado con ese nombre (IOBluetooth la da como «a8-81-…»).
- (NSString *)addressForName:(NSString *)name {
  for (IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
    if (name && [device.name caseInsensitiveCompare:name] == NSOrderedSame) {
      return [device.addressString.uppercaseString stringByReplacingOccurrencesOfString:@"-" withString:@":"];
    }
  }
  return nil;
}

- (void)startPeer:(NSString *)address name:(NSString *)name passive:(BOOL)passive {
  {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    NSString *failure = nil;
    if (!self.permission) {
      self.permission = [[CBCentralManager alloc] initWithDelegate:self queue:self.queue options:@{CBCentralManagerOptionShowPowerAlertKey : @NO}];
    }
    while (CBManager.authorization != CBManagerAuthorizationAllowedAlways) {
      if (CBManager.authorization == CBManagerAuthorizationDenied || CBManager.authorization == CBManagerAuthorizationRestricted) {
        failure = @"Bluetooth denegado: actívalo en Ajustes del Sistema › Privacidad › Bluetooth";
        break;
      }
      if (deadline.timeIntervalSinceNow < 0) { failure = @"Sin permiso de Bluetooth"; break; }
      usleep(100000);
    }
    if (!failure && !self.manager) {
      Class cls = NSClassFromString(@"CBClassicManager");
      self.manager = cls ? [(VHClassicManager *)[cls alloc] initWithQueue:self.queue options:@{@"kCBMsgArgIsPrivilegedDaemon" : @YES}] : nil;
      if (!self.manager) failure = @"CoreBluetooth ya no tiene CBClassicManager en este macOS";
      [self.manager setConnectCallback:^(VHClassicPeer *peer, NSInteger status) {
        event(@"peer_connected", @{@"status" : @(status)});
      }];
      [self.manager setDisconnectCallback:^(VHClassicPeer *peer, NSInteger status) {
        event(@"peer_disconnected", @{@"status" : @(status)});
      }];
    }
    // Recién creado, el manager tarda en encenderse (estado 5); antes de eso no acepta servicios.
    for (int i = 0; !failure && self.manager.state != 5 && i < 50; i++) usleep(100000);
    if (!failure && !self.serviceHandle) {
      [self.manager setTccApproved:YES];
      [self.manager doneWithTCC];
      self.serviceHandle = [self.manager addServiceWithData:[NSData dataWithBytes:kSDPRecord length:sizeof(kSDPRecord)]];
      [self.manager setBTConnectable:YES];
      [self.manager setBTDiscoverable:YES];
      if (!self.serviceHandle) failure = @"No se pudo publicar el servicio HID";
    }
    if (!failure && !address.length) address = [self addressForName:name];
    // Sin emparejamiento todavía: se espera a que el iPhone se conecte desde sus ajustes de Bluetooth.
    if (!failure && !address.length) {
      passive = YES;
      event(@"needs_pairing", @{@"name" : name ?: @""});
    }
    self.address = address;
    VHClassicPeer *peer = (failure || !address.length) ? nil : [self.manager retrievePeerWithAddress:address];
    if (!failure && address.length && !peer) failure = @"El iPhone no está emparejado por Bluetooth con esta Mac";
    if (peer) {
      [peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, NSInteger status) { [self opened:ch status:status]; }];
      [peer setDisconnectL2CAPCallback:^(CBL2CAPChannel *ch, NSInteger status) { [self closed:ch status:status]; }];
      if (!passive) {
        if (peer.state != 2) [self.manager connectPeer:peer options:@{}];
        while (peer.state != 2 && deadline.timeIntervalSinceNow > 0) usleep(50000);
        if (peer.state != 2) failure = @"El iPhone no aceptó la conexión Bluetooth";
      }
    }
    if (passive && !failure) {
      event(@"waiting", @{@"peer_state" : @(peer.state)});
      NSDate *wait = [NSDate dateWithTimeIntervalSinceNow:400];
      while (![self connected] && wait.timeIntervalSinceNow > 0) usleep(100000);
      deadline = [NSDate date];
    }
    NSDate *lastOpen = nil;
    while (!failure && ![self connected] && deadline.timeIntervalSinceNow > 0) {
      if (!lastOpen || -lastOpen.timeIntervalSinceNow > 2) {
        lastOpen = [NSDate date];
        [self.lock lock];
        BOOL needControl = self.channels[@(kControlPSM)] == nil;
        BOOL needInterrupt = self.channels[@(kInterruptPSM)] == nil;
        [self.lock unlock];
        if (needControl) [peer openL2CAPChannel:kControlPSM];
        if (needInterrupt) [peer openL2CAPChannel:kInterruptPSM];
      }
      usleep(100000);
    }
    if (!failure && ![self connected]) failure = @"No se abrieron los canales HID (¿AssistiveTouch activado en el iPhone?)";
    self.starting = NO;
    if (failure) event(@"error", @{@"message" : failure});
    else event(@"ready", @{});
  }
}

- (void)opened:(CBL2CAPChannel *)ch status:(NSInteger)status {
  event(@"channel_open", @{@"psm" : @(ch.PSM), @"status" : @(status)});
  if (status != 0 || ch.socketFD < 0) return;
  int fd = ch.socketFD;
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  int noSignal = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.queue);
  [self.lock lock];
  dispatch_source_t prior = self.readers[@(ch.PSM)];
  if (prior) dispatch_source_cancel(prior);
  self.channels[@(ch.PSM)] = ch;
  self.readers[@(ch.PSM)] = source;
  [self.lock unlock];
  // El iPhone pregunta por el canal de control (GET_REPORT, SET_PROTOCOL…): se responde como un HID normal.
  dispatch_source_set_event_handler(source, ^{
    uint8_t buffer[512];
    ssize_t n = recv(fd, buffer, sizeof(buffer), MSG_DONTWAIT);
    if (n <= 0) {
      if (n == 0 || (errno != EAGAIN && errno != EINTR)) [self closed:ch status:0];
      return;
    }
    if (ch.PSM != kControlPSM) return;
    uint8_t reply[16] = {0};
    size_t count = 1;
    uint8_t kind = buffer[0] & 0xf0;
    if (kind == 0x70) {
      reply[0] = (buffer[0] & 1) ? 0 : 4;
    } else if (kind == 0x60) {
      reply[0] = 0xa0;
      reply[1] = 1;
      count = 2;
    } else if (kind == 0x40) {
      uint8_t reportID = n > 1 ? buffer[1] : 1;
      if (reportID != 1 && reportID != 2) {
        reply[0] = 2;
      } else {
        NSUInteger length = reportID == 2 ? 11 : 9;
        reply[0] = 0xa1;
        reply[1] = reportID;
        count = 1 + length;
        [self.lock lock];
        NSData *last = self.lastReports[@(reportID)];
        [self.lock unlock];
        if (last.length == length) memcpy(reply + 1, last.bytes, length);
      }
    } else if (kind == 0x50 || kind == 0x90) {
      reply[0] = 0;
    } else if (kind == 0x80) {
      reply[0] = 0xa0;
      count = 2;
    } else if (kind == 0x10) {
      return;
    } else {
      reply[0] = 3;
    }
    packetWrite(fd, [NSData dataWithBytes:reply length:count]);
  });
  dispatch_resume(source);
}

- (void)closed:(CBL2CAPChannel *)ch status:(NSInteger)status {
  [self.lock lock];
  if (self.channels[@(ch.PSM)] && self.channels[@(ch.PSM)] != ch) {
    [self.lock unlock];
    return;
  }
  dispatch_source_t source = self.readers[@(ch.PSM)];
  if (source) dispatch_source_cancel(source);
  [self.readers removeObjectForKey:@(ch.PSM)];
  [self.channels removeObjectForKey:@(ch.PSM)];
  [self.lock unlock];
  event(@"channel_closed", @{@"psm" : @(ch.PSM), @"status" : @(status)});
}

/// Reporte del puntero absoluto: ID 2, 32 botones, X e Y de 0 a 32767 (little endian), rueda y AC Pan.
- (NSData *)reportX:(int)x y:(int)y buttons:(uint32_t)buttons wheel:(int)wheel pan:(int)pan {
  uint8_t report[11] = {2};
  memcpy(report + 1, &buttons, 4);
  uint16_t px = (uint16_t)MAX(0, MIN(32767, x));
  uint16_t py = (uint16_t)MAX(0, MIN(32767, y));
  memcpy(report + 5, &px, 2);
  memcpy(report + 7, &py, 2);
  report[9] = (uint8_t)(int8_t)MAX(-127, MIN(127, wheel));
  report[10] = (uint8_t)(int8_t)MAX(-127, MIN(127, pan));
  return [NSData dataWithBytes:report length:11];
}

- (NSData *)reportX:(int)x y:(int)y buttons:(uint32_t)buttons {
  return [self reportX:x y:y buttons:buttons wheel:0 pan:0];
}

/// La rueda actúa sobre lo que está bajo el puntero, sin presionar: el scroll no se «pega» a un botón.
- (void)scrollY:(int)dy x:(int)dx {
  dispatch_async(self.sendQueue, ^{
    NSData *report = [self reportX:self.lastX y:self.lastY buttons:self.lastButtons wheel:dy pan:dx];
    [self.mustSend addObject:@{@"report" : report, @"notBefore" : @(CFAbsoluteTimeGetCurrent())}];
    [self flush];
  });
}

/// El Bluetooth acepta menos reportes de los que da el mouse: los movimientos se agrupan (solo cuenta el
/// último) y los cambios de botón se encolan para que nunca se pierda un toque.
/// Al presionar, primero se lleva el puntero al punto y se espera un instante: si el movimiento y el clic van
/// juntos, iOS presiona donde estaba el puntero y lo arrastra hasta el destino. Después de presionar, el
/// «dedo» se queda quieto 100 ms: si se mueve enseguida, iOS lo toma como un toque y no como un arrastre
/// (mismos tiempos que los gestos de open-phone).
- (void)pointerX:(int)x y:(int)y buttons:(uint32_t)buttons {
  NSData *report = [self reportX:x y:y buttons:buttons];
  dispatch_async(self.sendQueue, ^{
    self.lastX = x;
    self.lastY = y;
    if (buttons != self.lastButtons) {
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      if (self.lastButtons == 0) {
        [self.mustSend addObject:@{@"report" : [self reportX:x y:y buttons:0], @"notBefore" : @(now)}];
        [self.mustSend addObject:@{@"report" : report, @"notBefore" : @(now + 0.05)}];
        self.moveNotBefore = now + 0.15;
      } else {
        [self.mustSend addObject:@{@"report" : report, @"notBefore" : @(now)}];
      }
      self.lastButtons = buttons;
      self.latestMove = nil;
    } else {
      self.latestMove = report;
    }
    [self flush];
  });
}

// Solo en sendQueue.
- (void)flush {
  while (self.mustSend.count) {
    NSDictionary *next = self.mustSend.firstObject;
    double wait = [next[@"notBefore"] doubleValue] - CFAbsoluteTimeGetCurrent();
    if (wait > 0) return [self retryAfter:wait];
    if (![self send:next[@"report"]]) return [self retryLater];
    [self.mustSend removeObjectAtIndex:0];
  }
  if (self.latestMove) {
    double hold = self.moveNotBefore - CFAbsoluteTimeGetCurrent();
    if (self.lastButtons != 0 && hold > 0) return [self retryAfter:hold];
    if (![self send:self.latestMove]) return [self retryLater];
    self.latestMove = nil;
  }
}

- (void)retryLater {
  [self retryAfter:0.004];
}

- (void)retryAfter:(double)seconds {
  if (self.retryScheduled) return;
  self.retryScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), self.sendQueue, ^{
    self.retryScheduled = NO;
    [self flush];
  });
}

/// NO solo cuando el canal está lleno (EAGAIN) y conviene reintentar; cualquier otro caso descarta el reporte.
- (BOOL)send:(NSData *)report {
  [self.lock lock];
  CBL2CAPChannel *channel = self.channels[@(kInterruptPSM)];
  self.lastReports[@2] = report;
  [self.lock unlock];
  if (!channel) return YES;
  NSMutableData *packet = [NSMutableData dataWithBytes:"\xa1" length:1];
  [packet appendData:report];
  ssize_t n = packetWrite(channel.socketFD, packet);
  if (n == (ssize_t)packet.length) return YES;
  if (n < 0 && (errno == EAGAIN || errno == ENOBUFS)) return NO;
  event(@"error", @{@"message" : [NSString stringWithFormat:@"No se pudo enviar el reporte (errno %d)", errno]});
  return YES;
}

/// Suelta el botón, cierra los canales y retira el servicio: el iPhone no se queda con un dedo «apoyado».
- (void)stop {
  [self.lock lock];
  NSData *last = self.lastReports[@2];
  BOOL hasChannel = self.channels[@(kInterruptPSM)] != nil;
  [self.lock unlock];
  if (hasChannel) {
    uint16_t x = 0, y = 0;
    if (last.length == 11) {
      memcpy(&x, (const uint8_t *)last.bytes + 5, 2);
      memcpy(&y, (const uint8_t *)last.bytes + 7, 2);
    }
    [self pointerX:x y:y buttons:0];
    for (int i = 0; i < 30; i++) {
      __block BOOL pending;
      dispatch_sync(self.sendQueue, ^{ pending = self.mustSend.count > 0; });
      if (!pending) break;
      usleep(5000);
    }
    usleep(40000);
  }
  if (self.address && self.manager) {
    VHClassicPeer *peer = [self.manager retrievePeerWithAddress:self.address];
    [self.lock lock];
    NSArray<NSNumber *> *open = self.channels.allKeys;
    [self.lock unlock];
    for (NSNumber *psm in open) [peer closeL2CAPChannel:psm.unsignedShortValue];
    if (open.count) usleep(150000);
  }
  if (self.serviceHandle) {
    [self.manager removeServiceHandle:self.serviceHandle];
    self.serviceHandle = 0;
  }
  [self.lock lock];
  for (dispatch_source_t source in self.readers.allValues) dispatch_source_cancel(source);
  [self.readers removeAllObjects];
  [self.channels removeAllObjects];
  [self.lock unlock];
}

- (void)handle:(NSDictionary *)request {
  NSString *cmd = request[@"cmd"];
  if ([cmd isEqual:@"pointer"]) {
    [self pointerX:[request[@"x"] intValue] y:[request[@"y"] intValue] buttons:[request[@"buttons"] unsignedIntValue]];
  } else if ([cmd isEqual:@"scroll"]) {
    [self scrollY:[request[@"dy"] intValue] x:[request[@"dx"] intValue]];
  } else if ([cmd isEqual:@"start"]) {
    [self startWithAddress:request[@"address"] name:request[@"name"] passive:[request[@"passive"] boolValue]];
  } else if ([cmd isEqual:@"status"]) {
    event(@"status", @{@"connected" : @([self connected]), @"authorization" : @(CBManager.authorization), @"service" : @(self.serviceHandle)});
  } else if ([cmd isEqual:@"stop"]) {
    [self stop];
    event(@"stopped", @{});
  }
}

@end

/// Lee órdenes hasta que el cliente cierra; entonces suelta todo y termina.
static void serveConnection(int inFD, int outFD) {
  [emitLock lock];
  clientFD = outFD;
  [emitLock unlock];
  event(@"hello", @{@"backend" : @"corebluetooth-classic"});
  FILE *input = fdopen(inFD, "r");
  char *line = NULL;
  size_t capacity = 0;
  while (getline(&line, &capacity, input) > 0) {
    @autoreleasepool {
      NSData *data = [NSData dataWithBytes:line length:strlen(line)];
      NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if (![request isKindOfClass:NSDictionary.class]) continue;
      @try {
        [controller handle:request];
      } @catch (NSException *exception) {
        event(@"error", @{@"message" : exception.reason ?: exception.name});
      }
    }
  }
  free(line);
  [controller stop];
  exit(0);
}

/// Un cliente a la vez por un socket Unix solo accesible para el usuario.
static void serve(NSString *path) {
  unlink(path.fileSystemRepresentation);
  int server = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  strlcpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path));
  if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(server, 1) != 0) {
    fprintf(stderr, "VisorHID: no pude abrir %s\n", path.UTF8String);
    exit(1);
  }
  chmod(path.fileSystemRepresentation, 0600);
  int fd = accept(server, NULL, NULL);
  close(server);
  unlink(path.fileSystemRepresentation);
  serveConnection(dup(fd), fd);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "Uso: VisorHID --stdio | <ruta-del-socket>\n");
      return 2;
    }
    NSString *path = [NSString stringWithUTF8String:argv[1]];
    emitLock = [NSLock new];
    controller = [Controller new];
    Method peer = class_getInstanceMethod(NSClassFromString(@"CBClassicPeer"), NSSelectorFromString(@"handleMsg:args:"));
    if (!peer) {
      fprintf(stderr, "VisorHID: CoreBluetooth no tiene CBClassicPeer en este macOS\n");
      return 3;
    }
    originalPeerMessage = method_setImplementation(peer, (IMP)peerMessage);
    signal(SIGPIPE, SIG_IGN);
    BOOL stdio = [path isEqual:@"--stdio"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      if (stdio) serveConnection(STDIN_FILENO, STDOUT_FILENO);
      else serve(path);
    });
    [[NSRunLoop currentRunLoop] run];
  }
  return 0;
}
