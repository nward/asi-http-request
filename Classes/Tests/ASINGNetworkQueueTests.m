//
//  ASINGNetworkQueueTests.m
//  Mac
//
//  Created by Ben Copsey on 26/05/2010.
//  Copyright 2010 All-Seeing Interactive. All rights reserved.
//

#import "ASINGNetworkQueueTests.h"
#import "ASIHTTPRequest.h"
#import "ASINGNetworkQueue.h"

@implementation ASINGNetworkQueueTests

- (void)testASINGNetworkQueue
{
	ASINGNetworkQueue *queue = [[[ASINGNetworkQueue alloc] init] autorelease];
	NSUInteger i;
	for (i=0; i<100; i++) {
		ASIHTTPRequest *request = [ASIHTTPRequest requestWithURL:[NSURL URLWithString:@"http://asi"]];
		//[request setDelegate:self];
		[queue addRequest:request];
	}
	[queue start];
}

- (void)requestFinished:(ASIHTTPRequest *)request
{
	NSLog(@"Done");
}

- (void)requestFailed:(ASIHTTPRequest *)request
{
	NSLog(@"%@",[request error]);
}

@end
