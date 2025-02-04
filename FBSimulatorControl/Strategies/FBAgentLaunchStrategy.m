/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBAgentLaunchStrategy.h"

#import <FBControlCore/FBControlCore.h>

#import <CoreSimulator/SimDevice.h>

#import "FBSimulator+Private.h"
#import "FBSimulatorAgentOperation.h"
#import "FBSimulatorError.h"
#import "FBSimulatorProcessFetcher.h"

typedef void (^FBAgentTerminationHandler)(int stat_loc);

@interface FBAgentLaunchStrategy ()

@property (nonatomic, strong, readonly) FBSimulator *simulator;
@property (nonatomic, strong, readonly) FBSimulatorProcessFetcher *processFetcher;

@end

@implementation FBAgentLaunchStrategy

#pragma mark Initializers

+ (instancetype)strategyWithSimulator:(FBSimulator *)simulator
{
  return [[self alloc] initWithSimulator:simulator];
}

- (instancetype)initWithSimulator:(FBSimulator *)simulator
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _simulator = simulator;
  _processFetcher = simulator.processFetcher;

  return self;
}

#pragma mark Long-Running Processes

- (FBFuture<id<FBLaunchedProcess>> *)launchAgent:(FBProcessSpawnConfiguration *)agentLaunch
{
  FBSimulator *simulator = self.simulator;

  return [[agentLaunch.io
    attach]
    onQueue:simulator.workQueue fmap:^(FBProcessIOAttachment *attachment) {
      // Launch the Process
      FBMutableFuture<NSNumber *> *processStatusFuture = [FBMutableFuture futureWithNameFormat:@"Process completion of %@ on %@", agentLaunch.launchPath, simulator.udid];
      FBFuture<NSNumber *> *launchFuture = [FBAgentLaunchStrategy
        launchAgentWithSimulator:simulator
        launchPath:agentLaunch.launchPath
        arguments:agentLaunch.arguments
        environment:agentLaunch.environment
        waitForDebugger:NO
        stdOut:attachment.stdOut
        stdErr:attachment.stdErr
        mode:agentLaunch.mode
        processStatusFuture:processStatusFuture];

      // Wrap in the container object
      return [FBSimulatorAgentOperation
        operationWithSimulator:simulator
        configuration:agentLaunch
        stdOut:agentLaunch.io.stdOut
        stdErr:agentLaunch.io.stdErr
        launchFuture:launchFuture
        processStatusFuture:processStatusFuture];
    }];
}

#pragma mark Short-Running Processes

- (FBFuture<NSNumber *> *)launchAndNotifyOfCompletion:(FBProcessSpawnConfiguration *)agentLaunch
{
  return [[self
    launchAgent:agentLaunch]
    onQueue:self.simulator.workQueue fmap:^(FBSimulatorAgentOperation *operation) {
      return [operation exitCode];
    }];
}

- (FBFuture<NSString *> *)launchConsumingStdout:(FBProcessSpawnConfiguration *)agentLaunch
{
  id<FBAccumulatingBuffer> consumer = FBDataBuffer.accumulatingBuffer;
  FBProcessIO *io = [[FBProcessIO alloc]
    initWithStdIn:agentLaunch.io.stdIn
    stdOut:[FBProcessOutput outputForDataConsumer:consumer]
    stdErr:agentLaunch.io.stdOut];
  FBProcessSpawnConfiguration *derived = [[FBProcessSpawnConfiguration alloc]
    initWithLaunchPath:agentLaunch.launchPath
    arguments:agentLaunch.arguments
    environment:agentLaunch.environment
    io:io
    mode:agentLaunch.mode];
  return [[self
    launchAndNotifyOfCompletion:derived]
    onQueue:self.simulator.workQueue map:^(NSNumber *_) {
      return [[NSString alloc] initWithData:consumer.data encoding:NSUTF8StringEncoding];
    }];
}

#pragma mark Helpers

+ (NSDictionary<NSString *, id> *)launchOptionsWithArguments:(NSArray<NSString *> *)arguments environment:(NSDictionary<NSString *, NSString *> *)environment waitForDebugger:(BOOL)waitForDebugger
{
  NSMutableDictionary<NSString *, id> *options = [NSMutableDictionary dictionary];
  options[@"arguments"] = arguments;
  options[@"environment"] = environment ? environment: @{@"__SOME_MAGIC__" : @"__IS_ALIVE__"};
  if (waitForDebugger) {
    options[@"wait_for_debugger"] = @1;
  }
  return options;
}

#pragma mark Private

+ (FBFuture<NSNumber *> *)launchAgentWithSimulator:(FBSimulator *)simulator launchPath:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments environment:(NSDictionary<NSString *, NSString *> *)environment waitForDebugger:(BOOL)waitForDebugger stdOut:(nullable FBProcessStreamAttachment *)stdOut stdErr:(nullable FBProcessStreamAttachment *)stdErr mode:(FBProcessSpawnMode)mode processStatusFuture:(FBMutableFuture<NSNumber *> *)processStatusFuture
{
  // Get the Options
  NSDictionary<NSString *, id> *options = [FBAgentLaunchStrategy
    simDeviceLaunchOptionsWithSimulator:simulator
    launchPath:launchPath
    arguments:arguments
    environment:environment
    waitForDebugger:waitForDebugger
    stdOut:stdOut
    stdErr:stdErr
    mode:mode];

  // The Process launches and terminates synchronously
  FBMutableFuture<NSNumber *> *launchFuture = [FBMutableFuture futureWithNameFormat:@"Launch of %@ on %@", launchPath, simulator.udid];
  [simulator.device
    spawnAsyncWithPath:launchPath
    options:options
    terminationQueue:simulator.workQueue
    terminationHandler:^(int stat_loc) {
      // Notify that we're done with the process
      [processStatusFuture resolveWithResult:@(stat_loc)];
      // Close any open file handles that we have.
      // This is important because otherwise any reader will stall forever.
      // The SimDevice APIs do not automatically close any file descriptor passed into them, so we need to do this on it's behalf.
      // This would not be an issue if using simctl directly, as the stdout/stderr of the simctl process would close when the simctl process terminates.
      // However, using the simctl approach, we don't get the pid of the spawned process, this is merely logged internally.
      // Failing to close this end of the file descriptor would lead to the write-end of any pipe to not be closed and therefore it would leak.
      close(stdOut.fileDescriptor);
      close(stdErr.fileDescriptor);
    }
    completionQueue:simulator.workQueue
    completionHandler:^(NSError *innerError, pid_t processIdentifier){
      if (innerError) {
        [launchFuture resolveWithError:innerError];
      } else {
        [launchFuture resolveWithResult:@(processIdentifier)];
      }
  }];
  return launchFuture;
}

+ (NSDictionary<NSString *, id> *)simDeviceLaunchOptionsWithSimulator:(FBSimulator *)simulator launchPath:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments environment:(NSDictionary<NSString *, NSString *> *)environment waitForDebugger:(BOOL)waitForDebugger stdOut:(nullable FBProcessStreamAttachment *)stdOut stdErr:(nullable FBProcessStreamAttachment *)stdErr mode:(FBProcessSpawnMode)mode
{
  // argv[0] should be launch path of the process. SimDevice does not do this automatically, so we need to add it.
  arguments = [@[launchPath] arrayByAddingObjectsFromArray:arguments];
  NSMutableDictionary<NSString *, id> *options = [[FBAgentLaunchStrategy launchOptionsWithArguments:arguments environment:environment waitForDebugger:waitForDebugger] mutableCopy];
  if (stdOut){
    options[@"stdout"] = @(stdOut.fileDescriptor);
  }
  if (stdErr) {
    options[@"stderr"] = @(stdErr.fileDescriptor);
  }
  options[@"standalone"] = @([self shouldLaunchStandaloneOnSimulator:simulator mode:mode]);
  return [options copy];
}

+ (BOOL)shouldLaunchStandaloneOnSimulator:(FBSimulator *)simulator mode:(FBProcessSpawnMode)mode
{
  // Standalone means "launch directly, not via launchd"
  switch (mode) {
    case FBProcessSpawnModeLaunchd:
      return NO;
    case FBProcessSpawnModePosixSpawn:
      return YES;
    default:
      // Default behaviour is to use launchd if booted, otherwise use standalone.
      return simulator.state != FBiOSTargetStateBooted;
  }
}

@end
