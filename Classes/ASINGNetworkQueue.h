//
//  ASINGNetworkQueue.h
//  Mac
//
//  Created by Ben Copsey on 26/05/2010.
//  Copyright 2010 All-Seeing Interactive. All rights reserved.
//

#import <Foundation/Foundation.h>
@class ASIHTTPRequest;

@interface ASINGNetworkQueue : NSObject {
	NSMutableArray *queuedRequests;
	NSMutableArray *runningRequests;
	NSLock *requestLock;
	NSThread *thread;
	NSTimer *requestStatusTimer;
}

- (void)addRequest:(ASIHTTPRequest *)request;
- (void)start;


@end
