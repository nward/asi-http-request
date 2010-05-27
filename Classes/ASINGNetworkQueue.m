//
//  ASINGNetworkQueue.m
//  Mac
//
//  Created by Ben Copsey on 26/05/2010.
//  Copyright 2010 All-Seeing Interactive. All rights reserved.
//

#import "ASINGNetworkQueue.h"
#import "ASIHTTPRequest.h"


@interface ASINGNetworkQueue ()

- (void)startRequest:(ASIHTTPRequest *)requestToRun;
- (void)reallyStartRequest:(ASIHTTPRequest *)requestToRun;
@property (retain, nonatomic) NSMutableArray *queuedRequests;
@property (retain, nonatomic) NSMutableArray *runningRequests;
@property (retain, nonatomic) NSLock *requestLock;
@property (retain, nonatomic) NSThread *thread;
@property (retain, nonatomic) NSTimer *requestStatusTimer;
@end

@implementation ASINGNetworkQueue

- (id)init
{
	self = [super init];
	[self setRequestLock:[[[NSLock alloc] init] autorelease]];
	[self setQueuedRequests:[NSMutableArray array]];
	[self setRunningRequests:[NSMutableArray array]];
	[self setThread:[[[NSThread alloc] initWithTarget:self selector:@selector(mainLoop) object:nil] autorelease]];
	return self;
}

- (void)dealloc
{
	[queuedRequests release];
	[runningRequests release];
	[requestLock release];
	[super dealloc];
}

- (void)addRequest:(ASIHTTPRequest *)request
{
	[request setQueue:self];
	[[self requestLock] lock];
	if ([[self runningRequests] count] > 3) {
		[[self queuedRequests] addObject:request];
	} else {
		[self startRequest:request];
	}
	[[self requestLock] unlock];
}

- (void)requestFinished:(ASIHTTPRequest *)request
{
	[[self requestLock] lock];
	[[self runningRequests] removeObject:request];
	if ([[self queuedRequests] count]) {
		[self startRequest:[[self queuedRequests] objectAtIndex:0]];
	} else {
		[[self requestStatusTimer] invalidate];
		[self setRequestStatusTimer:nil];
		
	}
	NSLog(@"done");
	[[self requestLock] unlock];
}
	
- (void)startRequest:(ASIHTTPRequest *)requestToRun
{
	[[self runningRequests] addObject:requestToRun];
	[[self queuedRequests] removeObject:requestToRun];
	[self performSelector:@selector(reallyStartRequest:) onThread:[self thread] withObject:requestToRun waitUntilDone:NO];	
}

- (void)reallyStartRequest:(ASIHTTPRequest *)requestToRun
{
	[[self requestLock] lock];
	if (![[self runningRequests] count]) {
		[[self requestStatusTimer] invalidate];
		[self setRequestStatusTimer:[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateRequestStatus:) userInfo:nil repeats:YES]];
	}
	[[self requestLock] unlock];
	[requestToRun main];
}
		 
- (void)updateRequestStatus
{
	[[self requestLock] lock];
	for (ASIHTTPRequest *request in [self runningRequests]) {
		[request updateStatus];
	}
	[[self requestLock] unlock];
}

- (void)start
{
	[[self thread] start];
	[[self requestLock] lock];
	while ([[self runningRequests] count] < 4) {
		[self startRequest:[[self queuedRequests] objectAtIndex:0]];
	}
	[[self requestLock] unlock];
}

- (void)pause
{
	[[self requestLock] lock];
	CFRunLoopStop(CFRunLoopGetCurrent());
	[[self requestLock] unlock];
}

- (void)cancel
{
	[[self requestLock] lock];
	CFRunLoopStop(CFRunLoopGetCurrent());
	[self setQueuedRequests:nil];
	for (ASIHTTPRequest *request in [self runningRequests]) {
		[request cancel];
	}
	[self setRunningRequests:nil];
	[[self requestLock] unlock];	
}

- (void)mainLoop
{
	[[NSRunLoop currentRunLoop] run];
}

@synthesize queuedRequests;
@synthesize runningRequests;
@synthesize requestLock;
@synthesize thread;
@synthesize requestStatusTimer;
@end
