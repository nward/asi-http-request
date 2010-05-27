//
//  ASINGNetworkQueue.h
//  Mac
//
//  Created by Ben Copsey on 26/05/2010.
//  Copyright 2010 All-Seeing Interactive. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "ASIHTTPRequestDelegate.h"
#import "ASIProgressDelegate.h"

@class ASIHTTPRequest;

@interface ASINGNetworkQueue : NSObject <ASIProgressDelegate, ASIHTTPRequestDelegate> {
	NSMutableArray *queuedRequests;
	NSMutableArray *runningRequests;
	NSRecursiveLock *requestLock;
	NSThread *thread;
	NSTimer *requestStatusTimer;
	
	// Delegate will get didFail + didFinish messages (if set)
	id delegate;
	
	// Will be called when a request starts with the request as the argument
	SEL requestDidStartSelector;
	
	// Will be called when a request receives response headers with the request as the argument
	SEL requestDidReceiveResponseHeadersSelector;
	
	// Will be called when a request completes with the request as the argument
	SEL requestDidFinishSelector;
	
	// Will be called when a request fails with the request as the argument
	SEL requestDidFailSelector;
	
	// Will be called when the queue finishes with the queue as the argument
	SEL queueDidFinishSelector;
	
	// Upload progress indicator, probably an NSProgressIndicator or UIProgressView
	id uploadProgressDelegate;
	
	// Total amount uploaded so far for all requests in this queue
	unsigned long long bytesUploadedSoFar;
	
	// Total amount to be uploaded for all requests in this queue - requests add to this figure as they work out how much data they have to transmit
	unsigned long long totalBytesToUpload;
	
	// Download progress indicator, probably an NSProgressIndicator or UIProgressView
	id downloadProgressDelegate;
	
	// Total amount downloaded so far for all requests in this queue
	unsigned long long bytesDownloadedSoFar;
	
	// Total amount to be downloaded for all requests in this queue - requests add to this figure as they receive Content-Length headers
	unsigned long long totalBytesToDownload;
	
	// When YES, the queue will cancel all requests when a request fails. Default is YES
	BOOL shouldCancelAllRequestsOnFailure;
	
	// When NO, this request will only update the progress indicator when it completes
	// When YES, this request will update the progress indicator according to how much data it has received so far
	// When YES, the queue will first perform HEAD requests for all GET requests in the queue, so it can calculate the total download size before it starts
	// NO means better performance, because it skips this step for GET requests, and it won't waste time updating the progress indicator until a request completes 
	// Set to YES if the size of a requests in the queue varies greatly for much more accurate results
	// Default for requests in the queue is NO
	BOOL showAccurateProgress;
	
	// Storage container for additional queue information.
	NSDictionary *userInfo;
	
	unsigned int maxConcurrentRequestCount;
	
}

+ (id)queue;
- (void)addRequest:(ASIHTTPRequest *)request;
- (void)cancelAllRequests;
- (void)start;

@property (assign,setter=setUploadProgressDelegate:) id uploadProgressDelegate;
@property (assign,setter=setDownloadProgressDelegate:) id downloadProgressDelegate;

@property (assign) SEL requestDidStartSelector;
@property (assign) SEL requestDidReceiveResponseHeadersSelector;
@property (assign) SEL requestDidFinishSelector;
@property (assign) SEL requestDidFailSelector;
@property (assign) SEL queueDidFinishSelector;
@property (assign) BOOL shouldCancelAllRequestsOnFailure;
@property (assign) id delegate;
@property (assign) BOOL showAccurateProgress;
@property (retain) NSDictionary *userInfo;

@property (assign) unsigned long long bytesUploadedSoFar;
@property (assign) unsigned long long totalBytesToUpload;
@property (assign) unsigned long long bytesDownloadedSoFar;
@property (assign) unsigned long long totalBytesToDownload;
@property (assign) unsigned int maxConcurrentRequestCount;

@end
