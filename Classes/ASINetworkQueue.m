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

@interface ASINetworkQueue ()

- (void)startRequest:(ASIHTTPRequest *)requestToRun;
- (void)resetProgressDelegate:(id)progressDelegate;
- (BOOL)startMoreRequests;

@property (retain, nonatomic) NSMutableArray *queuedRequests;
@property (retain, nonatomic) NSMutableArray *runningRequests;
@property (retain, nonatomic) NSRecursiveLock *requestLock;
@property (retain, nonatomic) NSThread *thread;
@property (retain, nonatomic) NSTimer *requestStatusTimer;
@property (retain, nonatomic) NSConditionLock *inProgressLock;
@end

@implementation ASINetworkQueue

- (id)init
{
	self = [super init];
	[self setInProgressLock:[[[NSConditionLock alloc] init] autorelease]];
	[self setRequestLock:[[[NSRecursiveLock alloc] init] autorelease]];
	[self setQueuedRequests:[NSMutableArray array]];
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
	[inProgressLock release];
	[requestStatusTimer invalidate];
	[requestStatusTimer release];
	[queuedRequests release];
	[runningRequests release];
	[requestLock release];
	[thread release];
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
	[[self requestLock] lock];
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
				[[self queuedRequests] addObject:HEADRequest];
				
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
	[[self requestLock] unlock];
}

- (void)requestFailed:(ASIHTTPRequest *)request
{
	[[self requestLock] lock];
	
	if ([self requestDidFailSelector] && ![request mainRequest]) {
		[[self delegate] performSelectorOnMainThread:[self requestDidFailSelector] withObject:request waitUntilDone:NO];
	}
	[[self queuedRequests] removeObject:request];
	[[self runningRequests] removeObject:request];
	if ([self shouldCancelAllRequestsOnFailure] && ([[self queuedRequests] count] || [[self runningRequests] count])) {
		[self cancelAllRequests];
	}
	if (![[self queuedRequests] count] && ![[self runningRequests] count]) {
		
		if ([self queueDidFinishSelector]) {
			[[self delegate] performSelectorOnMainThread:[self queueDidFinishSelector] withObject:self waitUntilDone:NO];
		}
		
		[self cancelAllRequests];
	}
	
	[[self requestLock] unlock];	
}

- (void)requestFinished:(ASIHTTPRequest *)request
{
	[[self requestLock] lock];
	
	if ([self requestDidFinishSelector] && ![request mainRequest]) {
		[[self delegate] performSelectorOnMainThread:[self requestDidFinishSelector] withObject:request waitUntilDone:NO];
	}
	
	[self startMoreRequests];
	[[self runningRequests] removeObject:request];
	
	
	if (![[self queuedRequests] count] && ![[self runningRequests] count]) {
		
		if ([self queueDidFinishSelector]) {
			[[self delegate] performSelectorOnMainThread:[self queueDidFinishSelector] withObject:self waitUntilDone:NO];
		}
		
		[self cancelAllRequests];

	}
	
	[[self requestLock] unlock];
}

- (BOOL)startMoreRequests
{
	if ([self isSuspended]) {
		return NO;
	}
	BOOL haveStartedRequests = NO;
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
		}
		i++;
	}
	return haveStartedRequests;
}
	
- (void)startRequest:(ASIHTTPRequest *)requestToRun
{
	[[self requestLock] lock];
	if (![self isSuspended]) {
		[[self runningRequests] addObject:requestToRun];
		[[self queuedRequests] removeObject:requestToRun];
		[[self inProgressLock] lock];
		[[self inProgressLock] unlockWithCondition:RequestsQueuedASINetworkQueueState];
		if (![self thread]) {
			[self setThread:[[[NSThread alloc] initWithTarget:self selector:@selector(mainLoop) object:nil] autorelease]];
			[[self thread] start];
		}
		[self performSelector:@selector(performRequest:) onThread:[self thread] withObject:requestToRun waitUntilDone:NO];
	}
	[[self requestLock] unlock];
}


- (void)performRequest:(ASIHTTPRequest *)requestToRun
{
	[[self inProgressLock] lock];
	[[self inProgressLock] unlockWithCondition:RequestsInProgressASINetworkQueueState];
	[requestToRun main];
}
		 
- (void)updateRequestStatus:(NSTimer *)timer
{
	[[self requestLock] lock];
	for (ASIHTTPRequest *request in [[[self runningRequests] copy] autorelease]) {
		[request updateStatus];
	}
	[[self requestLock] unlock];
}

- (void)go
{
	[self setSuspended:NO];
	if ([self startMoreRequests]) {
		[[self inProgressLock] lockWhenCondition:1];
		[[self inProgressLock] unlock];	
	}
}

- (void)cancelAllRequests
{
	[[self requestLock] lock];
	for (ASIHTTPRequest *request in [[[self queuedRequests] copy] autorelease]) {
		[request cancel];
	}
	for (ASIHTTPRequest *request in [[[self runningRequests] copy] autorelease]) {
		[request cancel];
	}
	[self setBytesUploadedSoFar:0];
	[self setTotalBytesToUpload:0];
	[self setBytesDownloadedSoFar:0];
	[self setTotalBytesToDownload:0];
	
	if ([self thread] && [[self thread] isExecuting]) {
		[self performSelector:@selector(stopThread) onThread:[self thread] withObject:nil waitUntilDone:YES];
	}
	
	[[self inProgressLock] lock];
	[[self inProgressLock] unlockWithCondition:QueueEmptyASINetworkQueueState];	

	[[self requestLock] unlock];	
}

- (void)stopThread
{
	[[self requestStatusTimer] invalidate];
	[self setRequestStatusTimer:nil];
	CFRunLoopStop(CFRunLoopGetCurrent());
	[self setThread:nil];

}

- (void)mainLoop
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	if (![self requestStatusTimer]) {
		[self setRequestStatusTimer:[NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(updateRequestStatus:) userInfo:nil repeats:YES]];
	}
	while (1) {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, FLT_MAX, NO);
		if (![self thread]) {
			break;
		}
	}
	[pool release];
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
		[[self delegate] performSelector:[self requestDidStartSelector] withObject:request];
	}
}

- (void)requestReceivedResponseHeaders:(ASIHTTPRequest *)request
{
	if ([self requestDidReceiveResponseHeadersSelector]) {
		[[self delegate] performSelector:[self requestDidReceiveResponseHeadersSelector] withObject:request];
	}	
}

- (void)waitUntilAllRequestsAreFinished
{
	[[self inProgressLock] lockWhenCondition:QueueEmptyASINetworkQueueState];
	[[self inProgressLock] unlock];	
	NSLog(@"foo");
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
@synthesize runningRequests;
@synthesize requestLock;
@synthesize thread;
@synthesize requestStatusTimer;
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
@synthesize inProgressLock;
@end
