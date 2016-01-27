/*
 * Copyright (c) 2015-2016 Spotify AB.
 *
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
#import "SPTDataLoaderFactory.h"

#import "SPTDataLoaderAuthoriser.h"
#import "SPTDataLoaderRequest.h"

#import "SPTDataLoaderFactory+Private.h"
#import "SPTDataLoader+Private.h"
#import "SPTDataLoaderResponse+Private.h"
#import "SPTDataLoaderRequest+Private.h"

@interface SPTDataLoaderFactory () <SPTDataLoaderRequestResponseHandlerDelegate, SPTDataLoaderAuthoriserDelegate>

@property (nonatomic, strong) NSMapTable *requestToRequestResponseHandler;

@end

@implementation SPTDataLoaderFactory

#pragma mark Private

+ (instancetype)dataLoaderFactoryWithRequestResponseHandlerDelegate:(id<SPTDataLoaderRequestResponseHandlerDelegate>)requestResponseHandlerDelegate
                                                        authorisers:(NSArray *)authorisers
{
    return [[self alloc] initWithRequestResponseHandlerDelegate:requestResponseHandlerDelegate authorisers:authorisers];
}

- (instancetype)initWithRequestResponseHandlerDelegate:(id<SPTDataLoaderRequestResponseHandlerDelegate>)requestResponseHandlerDelegate
                                           authorisers:(NSArray *)authorisers
{
    if (!(self = [super init])) {
        return nil;
    }
    
    _requestResponseHandlerDelegate = requestResponseHandlerDelegate;
    _authorisers = [authorisers copy];
    
    _requestToRequestResponseHandler = [NSMapTable weakToWeakObjectsMapTable];
    
    for (id<SPTDataLoaderAuthoriser> authoriser in _authorisers) {
        authoriser.delegate = self;
    }
    
    return self;
}

#pragma mark SPTDataLoaderFactory

- (SPTDataLoader *)createDataLoader
{
    return [SPTDataLoader dataLoaderWithRequestResponseHandlerDelegate:self];
}

#pragma mark SPTDataLoaderRequestResponseHandler

@synthesize requestResponseHandlerDelegate = _requestResponseHandlerDelegate;

- (void)successfulResponse:(SPTDataLoaderResponse *)response
{
    id<SPTDataLoaderRequestResponseHandler> requestResponseHandler = nil;
    @synchronized(self.requestToRequestResponseHandler) {
        requestResponseHandler = [self.requestToRequestResponseHandler objectForKey:response.request];
        [self.requestToRequestResponseHandler removeObjectForKey:response.request];
    }
    [requestResponseHandler successfulResponse:response];
}

- (void)failedResponse:(SPTDataLoaderResponse *)response
{
    // If we failed on authorisation and we have not retried the authorisation, retry it
    if (response.error.code == SPTDataLoaderResponseHTTPStatusCodeUnauthorised && !response.request.retriedAuthorisation) {
        for (id<SPTDataLoaderAuthoriser> authoriser in self.authorisers) {
            if ([authoriser requestRequiresAuthorisation:response.request]) {
                [authoriser requestFailedAuthorisation:response.request];
            }
        }
        response.request.retriedAuthorisation = YES;
        if ([self shouldAuthoriseRequest:response.request]) {
            [self authoriseRequest:response.request];
            return;
        }
    }
    
    id<SPTDataLoaderRequestResponseHandler> requestResponseHandler = nil;
    @synchronized(self.requestToRequestResponseHandler) {
        requestResponseHandler = [self.requestToRequestResponseHandler objectForKey:response.request];
        [self.requestToRequestResponseHandler removeObjectForKey:response.request];
    }
    [requestResponseHandler failedResponse:response];
}

- (void)cancelledRequest:(SPTDataLoaderRequest *)request
{
    id<SPTDataLoaderRequestResponseHandler> requestResponseHandler = nil;
    @synchronized(self.requestToRequestResponseHandler) {
        requestResponseHandler = [self.requestToRequestResponseHandler objectForKey:request];
        [self.requestToRequestResponseHandler removeObjectForKey:request];
    }
    [requestResponseHandler cancelledRequest:request];
}

- (void)receivedDataChunk:(NSData *)data forResponse:(SPTDataLoaderResponse *)response
{
    id<SPTDataLoaderRequestResponseHandler> requestResponseHandler = nil;
    @synchronized(self.requestToRequestResponseHandler) {
        requestResponseHandler = [self.requestToRequestResponseHandler objectForKey:response.request];
    }
    [requestResponseHandler receivedDataChunk:data forResponse:response];
}

- (void)receivedInitialResponse:(SPTDataLoaderResponse *)response
{
    id<SPTDataLoaderRequestResponseHandler> requestResponseHandler = nil;
    @synchronized(self.requestToRequestResponseHandler) {
        requestResponseHandler = [self.requestToRequestResponseHandler objectForKey:response.request];
    }
    [requestResponseHandler receivedInitialResponse:response];
}

- (BOOL)shouldAuthoriseRequest:(SPTDataLoaderRequest *)request
{
    for (id<SPTDataLoaderAuthoriser> authoriser in self.authorisers) {
        if ([authoriser requestRequiresAuthorisation:request]) {
            return YES;
        }
    }
    
    return NO;
}

- (void)authoriseRequest:(SPTDataLoaderRequest *)request
{
    for (id<SPTDataLoaderAuthoriser> authoriser in self.authorisers) {
        if ([authoriser requestRequiresAuthorisation:request]) {
            [authoriser authoriseRequest:request];
            return;
        }
    }
}

#pragma mark SPTDataLoaderRequestResponseHandlerDelegate

- (id<SPTCancellationToken>)requestResponseHandler:(id<SPTDataLoaderRequestResponseHandler>)requestResponseHandler
                                    performRequest:(SPTDataLoaderRequest *)request
{
    if (self.offline) {
        request.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    }
    
    @synchronized(self.requestToRequestResponseHandler) {
        [self.requestToRequestResponseHandler setObject:requestResponseHandler forKey:request];
    }
    
    // Add an absolute timeout for responses
    if (request.timeout > 0.0) {
        __weak __typeof(self) weakSelf = self;
        __weak __typeof(request) weakRequest = request;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(request.timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            
            SPTDataLoaderResponse *response = [SPTDataLoaderResponse dataLoaderResponseWithRequest:weakRequest
                                                                                          response:nil];
            NSError *error = [NSError errorWithDomain:SPTDataLoaderRequestErrorDomain
                                                 code:SPTDataLoaderRequestErrorCodeTimeout
                                             userInfo:nil];
            response.error = error;
            [strongSelf failedResponse:response];
        });
    }
    
    return [self.requestResponseHandlerDelegate requestResponseHandler:self performRequest:request];
}

#pragma mark SPTDataLoaderAuthoriserDelegate

- (void)dataLoaderAuthoriser:(id<SPTDataLoaderAuthoriser>)dataLoaderAuthoriser
           authorisedRequest:(SPTDataLoaderRequest *)request
{
    id<SPTDataLoaderRequestResponseHandlerDelegate> requestResponseHandlerDelegate = self.requestResponseHandlerDelegate;
    if ([requestResponseHandlerDelegate respondsToSelector:@selector(requestResponseHandler:authorisedRequest:)]) {
        [requestResponseHandlerDelegate requestResponseHandler:self authorisedRequest:request];
    }
}

- (void)dataLoaderAuthoriser:(id<SPTDataLoaderAuthoriser>)dataLoaderAuthoriser
   didFailToAuthoriseRequest:(SPTDataLoaderRequest *)request
                   withError:(NSError *)error
{
    id<SPTDataLoaderRequestResponseHandlerDelegate> requestResponseHandlerDelegate = self.requestResponseHandlerDelegate;
    if ([requestResponseHandlerDelegate respondsToSelector:@selector(requestResponseHandler:failedToAuthoriseRequest:error:)]) {
        [requestResponseHandlerDelegate requestResponseHandler:self failedToAuthoriseRequest:request error:error];
    }
}

@end
