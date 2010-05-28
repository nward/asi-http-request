//
//  ASINGNetworkQueue.m
//  Mac
//
//  Created by Ben Copsey on 26/05/2010.
//  Copyright 2010 All-Seeing Interactive. All rights reserved.
//

#import "ASINetworkQueue.h"
#import "ASIHTTPRequest.h"


enum _ASINetworkQueueState {
    QueueEmptyASINetworkQueueState = 0,
    RequestsQueuedASINetworkQueueState = 1,
    RequestsInProgressASINetworkQueueState = 2
};

// The thread all requests will run on
// Hangs around forever, but will be blocked unless there are requests underway
static NSThread *networkThread = nil;

// This lock is used to block the request thread to wait for more requests, and when waitUntilAllRequestsAreFinished is called
static NSConditionLock *queueStateLock;

// Updates the status of all running requests every 1/4 second
static NSTimer *statusTimer = nil;

// We store a reference to each queue when it is started, and remove it when it finishes
// This makes using auto-released queues possible
static NSMutableArray *queues = nil;

// Mediates accesss
static NSLock *modifyQueueLock = nil;

@interface ASINetworkQueue ()

- (void)startRequest:(ASIHTTPRequest *)requestToRun;
- (void)resetProgressDelegate:(id)progressDelegate;
- (BOOL)startMoreRequests;
- (void)queueFinished;

@property (retain, nonatomic) NSMutableArray *queuedRequests;
@property (retain, nonatomic) NSMutableArray *queuedHEADRequests;
@property (retain, nonatomic) NSMutableArray *runningRequests;
@property (retain, nonatomic) NSRecursiveLock *requestLock;
@property (assign, nonatomic) BOOL haveCalledQueueFinishSelector;
@end

@implementation ASINetworkQueue

+ (void)initialize
{
	if (self == [ASINetworkQueue class]) {
		networkThread = [[NSThread alloc] initWithTarget:self selector:@selector(runRequests) object:nil];
		queueStateLock = [[NSConditionLock alloc] init];
		modifyQueueLock = [[NSRecursiveLock alloc] init];
		queues = [[NSMutableArray array] retain];
		[networkThread start];
	}
}

// This is the main loop for the thread the requests run in
// Basically, it runs the runloop while there are requests in progress
// then blocks to wait for more requests to be added to the queue
+ (void)runRequests
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	while (1) {
		[queueStateLock lockWhenCondition:RequestsQueuedASINetworkQueueState];
		[queueStateLock unlock];
		CFRunLoopRun();
	}
	[pool release];
}

// Called to start off the timer that monitors the status of the running requests
+ (void)startStatusTimer
{
	if (!statusTimer) {
		statusTimer = [[NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(updateRequestStatus:) userInfo:nil repeats:YES] retain];
	}
}

// Called to stop the timer that monitors the status of the running requests when there are no more requests to monitor
+ (void)stopStatusTimer
{
	[statusTimer invalidate];
	[statusTimer release];
	statusTimer = nil;
}

// Called every 0.25 seconds when there are requests running
// The call to a request's updateStatus method will ensure requests update progress, and timeout if nescessary
+ (void)updateRequestStatus:(NSTimer *)timer
{
	[modifyQueueLock lock];
	for (ASINetworkQueue *queue in queues) {
		NSUInteger i;
		// updateStatus may remove the request from this list
		for (i=0; i<[[queue runningRequests] count]; i++) {
			[[[queue runningRequests] objectAtIndex:i] updateStatus];
		}
	}
	[modifyQueueLock unlock];
}

// Called on the request thread to run a request
+ (void)performRequest:(ASIHTTPRequest *)requestToRun
{
	[queueStateLock lock];
	[queueStateLock unlockWithCondition:RequestsInProgressASINetworkQueueState];
	[self startStatusTimer];
	[requestToRun main];
}


- (id)init
{
	self = [super init];
	[self setQueuedRequests:[NSMutableArray array]];
	[self setQueuedHEADRequests:[NSMutableArray array]];
	[self setRunningRequests:[NSMutableArray array]];
	[self setSuspended:YES];
	[self setShouldCancelAllRequestsOnFailure:YES];
	[self setMaxConcurrentRequestCount:4];
	return self;
}

+ (id)queue
{
	return [[[self alloc] init] autorelease];
}

- (void)dealloc
{
	[queuedRequests release];
	[queuedHEADRequests release];
	[runningRequests release];
	[super dealloc];
}

- (void)reset
{
	[self cancelAllRequests];
	[self setDelegate:nil];
	[self setDownloadProgressDelegate:nil];
	[self setUploadProgressDelegate:nil];
	[self setRequestDidStartSelector:NULL];
	[self setRequestDidReceiveResponseHeadersSelector:NULL];
	[self setRequestDidFailSelector:NULL];
	[self setRequestDidFinishSelector:NULL];
	[self setQueueDidFinishSelector:NULL];
	[self setSuspended:YES];
}


- (void)addRequest:(ASIHTTPRequest *)request
{
	[modifyQueueLock lock];
	[self setHaveCalledQueueFinishSelector:NO];
	
	if ([self showAccurateProgress]) {
		
		// Force the request to build its body (this may change requestMethod)
		[request buildPostBody];
		
		// If this is a GET request and we want accurate progress, perform a HEAD request first to get the content-length
		// We'll only do this before the queue is started
		// If requests are added after the queue is started they will probably move the overall progress backwards anyway, so there's no value performing the HEAD requests first
		// Instead, they'll update the total progress if and when they receive a content-length header
		if ([[request requestMethod] isEqualToString:@"GET"]) {
			if ([self isSuspended]) {
				ASIHTTPRequest *HEADRequest = [request HEADRequest];
				[HEADRequest setShowAccurateProgress:YES];
				[HEADRequest setQueue:self];
				[[self queuedHEADRequests] addObject:HEADRequest];
				
				if ([request shouldResetDownloadProgress]) {
					[self resetProgressDelegate:[request downloadProgressDelegate]];
					[request setShouldResetDownloadProgress:NO];
				}
			}
		}
		[request buildPostBody];
		[self request:nil incrementUploadSizeBy:[request postLength]];
		
		
	} else {
		[self request:nil incrementDownloadSizeBy:1];
		[self request:nil incrementUploadSizeBy:1];
	}
	// Tell the request not to increment the upload size when it starts, as we've already added its length
	if ([request shouldResetUploadProgress]) {
		[self resetProgressDelegate:[request uploadProgressDelegate]];
		[request setShouldResetUploadProgress:NO];
	}
	
	[request setShowAccurateProgress:[self showAccurateProgress]];
	
	[request setQueue:self];
	[[self queuedRequests] addObject:request];
	[self startMoreRequests];
	[modifyQueueLock unlock];
}

- (void)requestFailed:(ASIHTTPRequest *)request
{
	[modifyQueueLock lock];
	
	if ([self requestDidFailSelector] && ![request mainRequest]) {
		[[self delegate] performSelectorOnMainThread:[self requestDidFailSelector] withObject:request waitUntilDone:NO];
	}
	if ([request mainRequest]) {
		[[self queuedHEADRequests] removeObject:request];
	} else {
		[[self queuedRequests] removeObject:request];
	}
	[[self runningRequests] removeObject:request];

	if ([self shouldCancelAllRequestsOnFailure] && ([[self queuedRequests] count] || [[self runningRequests] count])) {
		[self cancelAllRequests];
	} else {
		[self startMoreRequests];
	}
	if (![[self queuedRequests] count] && ![[self runningRequests] count]) {
		
		if ([self queueDidFinishSelector] && ![self haveCalledQueueFinishSelector]) {
			[self setHaveCalledQueueFinishSelector:YES];
			[[self delegate] performSelectorOnMainThread:[self queueDidFinishSelector] withObject:self waitUntilDone:NO];
		}
		
		if ([queueStateLock condition] != QueueEmptyASINetworkQueueState) {
			[self queueFinished];
		}
	}
	
	[modifyQueueLock unlock];	
}

- (void)requestFinished:(ASIHTTPRequest *)request
{
	[modifyQueueLock lock];
	
	if ([self requestDidFinishSelector] && ![request mainRequest]) {
		[[self delegate] performSelectorOnMainThread:[self requestDidFinishSelector] withObject:request waitUntilDone:NO];
	}
	
	[[self runningRequests] removeObject:request];
	[self startMoreRequests];

	
	
	if (![[self queuedRequests] count] && ![[self runningRequests] count]) {
		
		if ([self queueDidFinishSelector] && ![self haveCalledQueueFinishSelector]) {
			[self setHaveCalledQueueFinishSelector:YES];
			[[self delegate] performSelectorOnMainThread:[self queueDidFinishSelector] withObject:self waitUntilDone:NO];
		}
		
		if ([queueStateLock condition] != QueueEmptyASINetworkQueueState) {
			[self queueFinished];
		}
	}
	
	[modifyQueueLock unlock];
}

- (BOOL)startMoreRequests
{
	if ([self isSuspended]) {
		return NO;
	}
	BOOL haveStartedRequests = NO;

	while ([[self queuedHEADRequests] count] && [[self runningRequests] count] < [self maxConcurrentRequestCount]) {
		[self startRequest:[[self queuedHEADRequests] objectAtIndex:0]];
		haveStartedRequests = YES;
	}

	NSUInteger i = 0;
	while (i < [[self queuedRequests] count] && [[self runningRequests] count] < [self maxConcurrentRequestCount]) {
		ASIHTTPRequest *requestToStart = [[self queuedRequests] objectAtIndex:i];
		BOOL HEADRequestInProgress = NO;
		for (ASIHTTPRequest *request in [self runningRequests]) {
			if ([request mainRequest] == requestToStart) {
				HEADRequestInProgress = YES;
				break;
			}
		}
		if (!HEADRequestInProgress) {
			[self startRequest:requestToStart];
			haveStartedRequests = YES;
		} else {
			i++;
		}
	}
	return haveStartedRequests;
}
	
- (void)startRequest:(ASIHTTPRequest *)requestToRun
{
	[modifyQueueLock lock];
	if (![queues containsObject:self]) {
		[queues addObject:self];
	}
	if (![self isSuspended]) {
		[[self runningRequests] addObject:requestToRun];
		if ([requestToRun mainRequest]) {
			[[self queuedHEADRequests] removeObject:requestToRun];
		} else {
			[[self queuedRequests] removeObject:requestToRun];
		}
		[queueStateLock lock];
		[queueStateLock unlockWithCondition:RequestsQueuedASINetworkQueueState];
		[[self class] performSelector:@selector(performRequest:) onThread:networkThread withObject:requestToRun waitUntilDone:NO];
	}
	[modifyQueueLock unlock];
}

- (void)go
{
	[modifyQueueLock lock];
	if (![queues containsObject:self]) {
		[queues addObject:self];
	}
	[modifyQueueLock unlock];
	[self setSuspended:NO];
	[self startMoreRequests];
}

- (void)cancelAllRequests
{
	[modifyQueueLock lock];

	NSArray *queuedRequestsToCancel = [[[self queuedRequests] copy] autorelease];
	NSArray *runningRequestsToCancel = [[[self runningRequests] copy] autorelease];
	[self setQueuedRequests:[NSMutableArray array]];
	[self setRunningRequests:[NSMutableArray array]];
	for (ASIHTTPRequest *request in queuedRequestsToCancel) {
		[request cancel];
	}
	for (ASIHTTPRequest *request in runningRequestsToCancel) {
		[request cancel];
	}
	[self setBytesUploadedSoFar:0];
	[self setTotalBytesToUpload:0];
	[self setBytesDownloadedSoFar:0];
	[self setTotalBytesToDownload:0];
	
	if ([queueStateLock condition] != QueueEmptyASINetworkQueueState) {
		[self queueFinished];
	}
	[modifyQueueLock unlock];
}

- (void)queueFinished
{
	[modifyQueueLock lock];
	[queues removeObject:self];
	if (![queues count]) {
		[[self class] stopStatusTimer];
		CFRunLoopStop(CFRunLoopGetCurrent());
		[queueStateLock lock];
		[queueStateLock unlockWithCondition:QueueEmptyASINetworkQueueState];
	}
	[modifyQueueLock unlock];
}

- (void)request:(ASIHTTPRequest *)request didReceiveBytes:(long long)bytes
{
	[self setBytesDownloadedSoFar:[self bytesDownloadedSoFar]+bytes];
	if ([self downloadProgressDelegate]) {
		[ASIHTTPRequest updateProgressIndicator:[self downloadProgressDelegate] withProgress:[self bytesDownloadedSoFar] ofTotal:[self totalBytesToDownload]];
	}
}

- (void)request:(ASIHTTPRequest *)request didSendBytes:(long long)bytes
{
	[self setBytesUploadedSoFar:[self bytesUploadedSoFar]+bytes];
	if ([self uploadProgressDelegate]) {
		[ASIHTTPRequest updateProgressIndicator:[self uploadProgressDelegate] withProgress:[self bytesUploadedSoFar] ofTotal:[self totalBytesToUpload]];
	}
}

- (void)request:(ASIHTTPRequest *)request incrementDownloadSizeBy:(long long)newLength
{
	[self setTotalBytesToDownload:[self totalBytesToDownload]+newLength];
}

- (void)request:(ASIHTTPRequest *)request incrementUploadSizeBy:(long long)newLength
{
	[self setTotalBytesToUpload:[self totalBytesToUpload]+newLength];
}

- (void)setUploadProgressDelegate:(id)newDelegate
{
	uploadProgressDelegate = newDelegate;
	[self resetProgressDelegate:newDelegate];
}

- (void)setDownloadProgressDelegate:(id)newDelegate
{
	downloadProgressDelegate = newDelegate;
	[self resetProgressDelegate:newDelegate];
}

- (void)resetProgressDelegate:(id)progressDelegate
{
#if !TARGET_OS_IPHONE
	// If the uploadProgressDelegate is an NSProgressIndicator, we set its MaxValue to 1.0 so we can treat it similarly to UIProgressViews
	SEL selector = @selector(setMaxValue:);
	if ([progressDelegate respondsToSelector:selector]) {
		double max = 1.0;
		[ASIHTTPRequest performSelector:selector onTarget:progressDelegate withObject:nil amount:&max];
	}
	selector = @selector(setDoubleValue:);
	if ([progressDelegate respondsToSelector:selector]) {
		double value = 0.0;
		[ASIHTTPRequest performSelector:selector onTarget:progressDelegate withObject:nil amount:&value];
	}
#else
	SEL selector = @selector(setProgress:);
	if ([progressDelegate respondsToSelector:selector]) {
		float value = 0.0f;
		[ASIHTTPRequest performSelector:selector onTarget:progressDelegate withObject:nil amount:&value];
	}
#endif
}

- (void)requestStarted:(ASIHTTPRequest *)request
{
	if ([self requestDidStartSelector]) {
		[[self delegate] performSelectorOnMainThread:[self requestDidStartSelector] withObject:request waitUntilDone:NO];
	}
}

- (void)requestReceivedResponseHeaders:(ASIHTTPRequest *)request
{
	if ([self requestDidReceiveResponseHeadersSelector]) {
		[[self delegate] performSelectorOnMainThread:[self requestDidReceiveResponseHeadersSelector] withObject:request waitUntilDone:NO];
	}	
}

- (void)waitUntilAllRequestsAreFinished
{
	[queueStateLock lockWhenCondition:QueueEmptyASINetworkQueueState];
	[queueStateLock unlock];	
}

- (NSUInteger)requestsCount
{
	[[self requestLock] lock];
	NSUInteger count = [[self runningRequests] count]+[[self queuedRequests] count]; 
	[[self requestLock] unlock];
	return count;
}

#pragma mark NSCopying

- (id)copyWithZone:(NSZone *)zone
{
	ASINetworkQueue *newQueue = [[[self class] alloc] init];
	[newQueue setDelegate:[self delegate]];
	[newQueue setMaxConcurrentRequestCount:[self maxConcurrentRequestCount]];
	[newQueue setRequestDidStartSelector:[self requestDidStartSelector]];
	[newQueue setRequestDidFinishSelector:[self requestDidFinishSelector]];
	[newQueue setRequestDidFailSelector:[self requestDidFailSelector]];
	[newQueue setQueueDidFinishSelector:[self queueDidFinishSelector]];
	[newQueue setUploadProgressDelegate:[self uploadProgressDelegate]];
	[newQueue setDownloadProgressDelegate:[self downloadProgressDelegate]];
	[newQueue setShouldCancelAllRequestsOnFailure:[self shouldCancelAllRequestsOnFailure]];
	[newQueue setShowAccurateProgress:[self showAccurateProgress]];
	[newQueue setUserInfo:[[[self userInfo] copyWithZone:zone] autorelease]];
	return newQueue;
}

// Since this queue takes over as the delegate for all requests it contains, it should forward authorisation requests to its own delegate
- (void)authenticationNeededForRequest:(ASIHTTPRequest *)request
{
	if ([[self delegate] respondsToSelector:@selector(authenticationNeededForRequest:)]) {
		[[self delegate] performSelector:@selector(authenticationNeededForRequest:) withObject:request];
	}
}

- (void)proxyAuthenticationNeededForRequest:(ASIHTTPRequest *)request
{
	if ([[self delegate] respondsToSelector:@selector(proxyAuthenticationNeededForRequest:)]) {
		[[self delegate] performSelector:@selector(proxyAuthenticationNeededForRequest:) withObject:request];
	}
}


- (BOOL)respondsToSelector:(SEL)selector
{
	if (selector == @selector(authenticationNeededForRequest:)) {
		if ([[self delegate] respondsToSelector:@selector(authenticationNeededForRequest:)]) {
			return YES;
		}
		return NO;
	} else if (selector == @selector(proxyAuthenticationNeededForRequest:)) {
		if ([[self delegate] respondsToSelector:@selector(proxyAuthenticationNeededForRequest:)]) {
			return YES;
		}
		return NO;
	}
	return [super respondsToSelector:selector];
}

@synthesize queuedRequests;
@synthesize queuedHEADRequests;
@synthesize runningRequests;
@synthesize requestLock;
@synthesize suspended;
@synthesize bytesUploadedSoFar;
@synthesize totalBytesToUpload;
@synthesize bytesDownloadedSoFar;
@synthesize totalBytesToDownload;
@synthesize shouldCancelAllRequestsOnFailure;
@synthesize uploadProgressDelegate;
@synthesize downloadProgressDelegate;
@synthesize requestDidStartSelector;
@synthesize requestDidReceiveResponseHeadersSelector;
@synthesize requestDidFinishSelector;
@synthesize requestDidFailSelector;
@synthesize queueDidFinishSelector;
@synthesize delegate;
@synthesize showAccurateProgress;
@synthesize userInfo;
@synthesize maxConcurrentRequestCount;
@synthesize haveCalledQueueFinishSelector;
@end
