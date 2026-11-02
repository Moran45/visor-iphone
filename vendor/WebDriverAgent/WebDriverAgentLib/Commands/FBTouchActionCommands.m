/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTouchActionCommands.h"

#import "FBErrorBuilder.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "XCUIApplication+FBTouchAction.h"

@implementation FBTouchActionCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute POST:@"/actions"] respondWithTarget:self action:@selector(handlePerformW3CTouchActions:)],
    // Visor iPhone: eventos directos, sin consultar la jerarquía de accesibilidad de la app.
    [[FBRoute POST:@"/wda/visor/touch"].withoutSession respondWithTarget:self action:@selector(handleVisorTouch:)],
    [[FBRoute POST:@"/wda/visor/type"].withoutSession respondWithTarget:self action:@selector(handleVisorType:)],
  ];
}

#pragma mark - Visor iPhone

/**
 Toque o arrastre en coordinadas de pantalla vertical: {"points": [[x, y, segundos], ...], "hold": segundos}.
 XCTest normalmente busca la app al frente y su orientación antes de cada gesto (3 o 4 consultas de
 accesibilidad, ~0,5 s); aquí se arma el evento y se manda tal cual.
 */
+ (id<FBResponsePayload>)handleVisorTouch:(FBRouteRequest *)request
{
  NSArray<NSArray<NSNumber *> *> *points = request.arguments[@"points"];
  if (![points isKindOfClass:NSArray.class] || points.count == 0 || points.firstObject.count < 2) {
    return FBResponseWithUnknownError([[FBErrorBuilder.builder withDescription:@"points must be [[x, y, t], ...]"] build]);
  }
  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"Visor touch"
                                                               interfaceOrientation:UIInterfaceOrientationPortrait];
  NSArray<NSNumber *> *first = points.firstObject;
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(first[0].doubleValue, first[1].doubleValue)
                                                                      offset:0];
  double offset = 0;
  for (NSUInteger i = 1; i < points.count; i++) {
    NSArray<NSNumber *> *point = points[i];
    offset = MAX(offset, point.count > 2 ? point[2].doubleValue : offset + 0.016);
    [path moveToPoint:CGPointMake(point[0].doubleValue, point[1].doubleValue) atOffset:offset];
  }
  [path liftUpAtOffset:MAX(MAX(offset, [request.arguments[@"hold"] doubleValue]), 0.05)];
  [record addPointerEventPath:path];
  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

/** Escribe texto como un teclado de hardware, sin buscar antes el campo con foco: {"text": "..."}. */
+ (id<FBResponsePayload>)handleVisorType:(FBRouteRequest *)request
{
  NSString *text = request.arguments[@"text"];
  if (![text isKindOfClass:NSString.class] || text.length == 0) {
    return FBResponseWithOK();
  }
  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"Visor type"
                                                               interfaceOrientation:UIInterfaceOrientationPortrait];
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTextInput];
  [path typeText:text atOffset:0 typingSpeed:60 shouldRedact:NO];
  [record addPointerEventPath:path];
  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

#pragma mark - Commands

+ (id<FBResponsePayload>)handlePerformW3CTouchActions:(FBRouteRequest *)request
{
  XCUIApplication *application = request.session.activeApplication;
  NSArray *actions = (NSArray *)request.arguments[@"actions"];
  NSError *error;
  if (![application fb_performW3CActions:actions elementCache:request.session.elementCache error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

@end
