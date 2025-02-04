/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSimulatorApplicationLaunchStrategy.h"

#import <FBControlCore/FBControlCore.h>

#import <CoreSimulator/SimDevice.h>

#import "FBAgentLaunchStrategy.h"
#import "FBSimulator+Private.h"
#import "FBSimulator.h"
#import "FBSimulatorApplicationLaunchStrategy.h"
#import "FBSimulatorApplicationOperation.h"
#import "FBSimulatorBridge.h"
#import "FBSimulatorConnection.h"
#import "FBSimulatorError.h"
#import "FBSimulatorLaunchCtlCommands.h"
#import "FBSimulatorProcessFetcher.h"
#import "FBSimulatorSubprocessTerminationStrategy.h"

@interface FBSimulatorApplicationLaunchStrategy ()

@property (nonnull, nonatomic, strong, readonly) FBSimulator *simulator;

@end

@interface FBSimulatorApplicationLaunchStrategy_Bridge : FBSimulatorApplicationLaunchStrategy

@end

@interface FBSimulatorApplicationLaunchStrategy_CoreSimulator : FBSimulatorApplicationLaunchStrategy

@end

@implementation FBSimulatorApplicationLaunchStrategy

#pragma mark Initializers

+ (instancetype)strategyWithSimulator:(FBSimulator *)simulator
{
  return [[self alloc] initWithSimulator:simulator];
}

- (instancetype)initWithSimulator:(FBSimulator *)simulator
{
  self = [super init];
  if (!self){
    return nil;
  }

  _simulator = simulator;

  return self;
}

#pragma mark Public

- (FBFuture<FBSimulatorApplicationOperation *> *)launchApplication:(FBApplicationLaunchConfiguration *)appLaunch
{
  FBSimulator *simulator = self.simulator;
  FBProcessIO *io = appLaunch.io;
  return [[[FBFuture futureWithFutures:@[
      [self ensureApplicationIsInstalled:appLaunch.bundleID],
      [self confirmApplicationLaunchState:appLaunch.bundleID launchMode:appLaunch.launchMode waitForDebugger:appLaunch.waitForDebugger],
    ]]
    onQueue:simulator.workQueue fmap:^(id _) {
      return [io attachViaFile];
    }]
    onQueue:simulator.workQueue fmap:^ FBFuture<FBSimulatorApplicationOperation *> * (FBProcessFileAttachment *attachment) {
      FBFuture<NSNumber *> *launch = [self launchApplication:appLaunch stdOut:attachment.stdOut stdErr:attachment.stdErr];
      return [FBSimulatorApplicationOperation operationWithSimulator:simulator configuration:appLaunch stdOut:attachment.stdOut stdErr:attachment.stdErr launchFuture:launch];
    }];
}

#pragma mark Private

- (FBFuture<NSNumber *> *)ensureApplicationIsInstalled:(NSString *)bundleID
{
  return [[[self.simulator
    installedApplicationWithBundleID:bundleID]
    mapReplace:NSNull.null]
    onQueue:self.simulator.asyncQueue handleError:^(NSError *error) {
      return [[FBSimulatorError
        describeFormat:@"App %@ can't be launched as it isn't installed: %@", bundleID, error]
        failFuture];
    }];
}

- (FBFuture<NSNumber *> *)confirmApplicationLaunchState:(NSString *)bundleID launchMode:(FBApplicationLaunchMode)launchMode waitForDebugger:(BOOL)waitForDebugger
{
  if (waitForDebugger && launchMode == FBApplicationLaunchModeForegroundIfRunning) {
    return [[FBSimulatorError
      describe:@"'Foreground if running' and 'wait for debugger cannot be applied simultaneously"]
      failFuture];
  }

  FBSimulator *simulator = self.simulator;
  return [[simulator
    processIDWithBundleID:bundleID]
    onQueue:simulator.asyncQueue chain:^ FBFuture<NSNull *> * (FBFuture<NSNumber *> *processFuture) {
      NSNumber *processID = processFuture.result;
      if (!processID) {
        return FBFuture.empty;
      }
      if (launchMode == FBApplicationLaunchModeFailIfRunning) {
        return [[FBSimulatorError
          describeFormat:@"App %@ can't be launched as is running (PID=%@)", bundleID, processID]
          failFuture];
      } else if (launchMode == FBApplicationLaunchModeRelaunchIfRunning) {
        return [[FBSimulatorSubprocessTerminationStrategy
          strategyWithSimulator:simulator]
          terminateApplication:bundleID];
      }
      return FBFuture.empty;
  }];
}

- (FBFuture<NSNumber *> *)launchApplication:(FBApplicationLaunchConfiguration *)appLaunch stdOut:(id<FBProcessFileOutput>)stdOut stdErr:(id<FBProcessFileOutput>)stdErr
{
  // Start reading now, but don't block on the resolution, we will ensure that the read has started after the app has launched.
  FBFuture *readingFutures = [FBFuture futureWithFutures:@[
    [stdOut startReading],
    [stdErr startReading],
  ]];

  return [[self
    launchApplication:appLaunch stdOutPath:stdOut.filePath stdErrPath:stdErr.filePath]
    onQueue:self.simulator.workQueue fmap:^(NSNumber *result) {
      return [readingFutures mapReplace:result];
    }];
}

- (FBFuture<NSNumber *> *)isApplicationRunning:(NSString *)bundleID
{
  return [[self.simulator
    processIDWithBundleID:bundleID]
    onQueue:self.simulator.workQueue chain:^(FBFuture<NSNumber *> *future){
      NSNumber *processIdentifier = future.result;
      return processIdentifier ? [FBFuture futureWithResult:@YES] : [FBFuture futureWithResult:@NO];
    }];
}

- (FBFuture<NSNumber *> *)launchApplication:(FBApplicationLaunchConfiguration *)appLaunch stdOutPath:(NSString *)stdOutPath stdErrPath:(NSString *)stdErrPath
{
  FBSimulator *simulator = self.simulator;
  NSDictionary<NSString *, id> *options = [FBSimulatorApplicationLaunchStrategy
    simDeviceLaunchOptionsForAppLaunch:appLaunch
    stdOutPath:[self translateAbsolutePath:stdOutPath toPathRelativeTo:simulator.dataDirectory]
    stdErrPath:[self translateAbsolutePath:stdErrPath toPathRelativeTo:simulator.dataDirectory]];

  FBMutableFuture<NSNumber *> *future = [FBMutableFuture future];
  [simulator.device launchApplicationAsyncWithID:appLaunch.bundleID options:options completionQueue:simulator.workQueue completionHandler:^(NSError *error, pid_t pid){
    if (error) {
      [future resolveWithError:error];
    } else {
      [future resolveWithResult:@(pid)];
    }
  }];
  return future;
}

- (NSString *)translateAbsolutePath:(NSString *)absolutePath toPathRelativeTo:(NSString *)referencePath
{
  if (![absolutePath hasPrefix:@"/"]) {
    return absolutePath;
  }
  // When launching an application with a custom stdout/stderr path, `SimDevice` uses the given path relative
  // to the Simulator's data directory. From the Framework's consumer point of view this might not be the
  // wanted behaviour. To work around it, we construct a path relative to the Simulator's data directory
  // using `..` until we end up in the absolute path outside the Simulator's data directory.
  NSString *translatedPath = @"";
  for (NSUInteger index = 0; index < referencePath.pathComponents.count; index++) {
    translatedPath = [translatedPath stringByAppendingPathComponent:@".."];
  }
  return [translatedPath stringByAppendingPathComponent:absolutePath];
}

+ (NSDictionary<NSString *, id> *)simDeviceLaunchOptionsForAppLaunch:(FBApplicationLaunchConfiguration *)appLaunch stdOutPath:(nullable NSString *)stdOutPath stdErrPath:(nullable NSString *)stdErrPath
{
  NSMutableDictionary<NSString *, id> *options = [[FBAgentLaunchStrategy launchOptionsWithArguments:appLaunch.arguments environment:appLaunch.environment waitForDebugger:appLaunch.waitForDebugger] mutableCopy];
  if (stdOutPath){
    options[@"stdout"] = stdOutPath;
  }
  if (stdErrPath) {
    options[@"stderr"] = stdErrPath;
  }
  return [options copy];
}


@end
