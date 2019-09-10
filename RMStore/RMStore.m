//
//  RMStore.h
//  RMStore
//
//  Created by Hermes Pique on 12/6/09.
//  Copyright (c) 2013 Robot Media SL (http://www.robotmedia.net)
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "RMStore.h"

NSString *const RMStoreErrorDomain = @"net.robotmedia.store";
NSInteger const RMStoreErrorCodeDownloadCanceled = 300;
NSInteger const RMStoreErrorCodeUnknownProductIdentifier = 100;
NSInteger const RMStoreErrorCodeUnableToCompleteVerification = 200;

NSString* const RMSKDownloadCanceled = @"RMSKDownloadCanceled";
NSString* const RMSKDownloadFailed = @"RMSKDownloadFailed";
NSString* const RMSKDownloadFinished = @"RMSKDownloadFinished";
NSString* const RMSKDownloadPaused = @"RMSKDownloadPaused";
NSString* const RMSKDownloadUpdated = @"RMSKDownloadUpdated";
NSString* const RMSKPaymentTransactionDeferred = @"RMSKPaymentTransactionDeferred";
NSString* const RMSKPaymentTransactionFailed = @"RMSKPaymentTransactionFailed";
NSString* const RMSKPaymentTransactionFinished = @"RMSKPaymentTransactionFinished";
NSString* const RMSKProductsRequestFailed = @"RMSKProductsRequestFailed";
NSString* const RMSKProductsRequestFinished = @"RMSKProductsRequestFinished";
NSString* const RMSKRefreshReceiptFailed = @"RMSKRefreshReceiptFailed";
NSString* const RMSKRefreshReceiptFinished = @"RMSKRefreshReceiptFinished";
NSString* const RMSKRestoreTransactionsFailed = @"RMSKRestoreTransactionsFailed";
NSString* const RMSKRestoreTransactionsFinished = @"RMSKRestoreTransactionsFinished";

NSString* const RMStoreNotificationInvalidProductIdentifiers = @"invalidProductIdentifiers";
NSString* const RMStoreNotificationDownloadProgress = @"downloadProgress";
NSString* const RMStoreNotificationProductIdentifier = @"productIdentifier";
NSString* const RMStoreNotificationProducts = @"products";
NSString* const RMStoreNotificationStoreDownload = @"storeDownload";
NSString* const RMStoreNotificationStoreError = @"storeError";
NSString* const RMStoreNotificationStoreReceipt = @"storeReceipt";
NSString* const RMStoreNotificationTransaction = @"transaction";
NSString* const RMStoreNotificationTransactions = @"transactions";

#if DEBUG
#define RMStoreLog(...) NSLog(@"RMStore: %@", [NSString stringWithFormat:__VA_ARGS__]);
#else
#define RMStoreLog(...)
#endif

typedef void (^RMSKPaymentTransactionFailureBlock)(SKPaymentTransaction *transaction, NSError *error);
typedef void (^RMSKPaymentTransactionSuccessBlock)(SKPaymentTransaction *transaction);
typedef void (^RMSKProductsRequestFailureBlock)(NSError *error);
typedef void (^RMSKProductsRequestSuccessBlock)(NSArray *products, NSArray *invalidIdentifiers);
typedef void (^RMStoreFailureBlock)(NSError *error);
typedef void (^RMStoreSuccessBlock)();

@implementation NSNotification(RMStore)

- (float)rm_downloadProgress
{
    return [self.userInfo[RMStoreNotificationDownloadProgress] floatValue];
}

- (NSArray*)rm_invalidProductIdentifiers
{
    return (self.userInfo)[RMStoreNotificationInvalidProductIdentifiers];
}

- (NSString*)rm_productIdentifier
{
    return (self.userInfo)[RMStoreNotificationProductIdentifier];
}

- (NSArray*)rm_products
{
    return (self.userInfo)[RMStoreNotificationProducts];
}

- (SKDownload*)rm_storeDownload
{
    return (self.userInfo)[RMStoreNotificationStoreDownload];
}

- (NSError*)rm_storeError
{
    return (self.userInfo)[RMStoreNotificationStoreError];
}

- (SKPaymentTransaction*)rm_transaction
{
    return (self.userInfo)[RMStoreNotificationTransaction];
}

- (NSArray*)rm_transactions {
    return (self.userInfo)[RMStoreNotificationTransactions];
}

@end

@interface RMProductsRequestDelegate : NSObject<SKProductsRequestDelegate>

@property (copy) RMSKProductsRequestSuccessBlock successBlock;
@property (copy) RMSKProductsRequestFailureBlock failureBlock;
@property (nonatomic, weak) RMStore *store;

@end

@interface RMAddPaymentParameters : NSObject

@property (copy) RMSKPaymentTransactionSuccessBlock successBlock;
@property (copy) RMSKPaymentTransactionFailureBlock failureBlock;

@end

@implementation RMAddPaymentParameters

@end

@interface RMStore() <SKRequestDelegate>

@property NSMutableDictionary<NSString*, RMAddPaymentParameters*>* addPaymentParameters; // HACK: We use a dictionary of product identifiers because the returned SKPayment is different from the one we add to the queue. Bad Apple.
@property NSMutableSet<NSString*>* deferredProductIds; // [NAK]

@property NSMutableDictionary<NSString*, SKProduct*>* products;
@property NSMutableSet<RMProductsRequestDelegate*>* productsRequestDelegates;

@property NSMutableArray<SKPaymentTransaction*>* restoredTransactions;

@property NSInteger pendingRestoredTransactionsCount;
@property BOOL restoredCompletedTransactionsFinished;

@property SKReceiptRefreshRequest* refreshReceiptRequest;
@property (copy) void (^refreshReceiptFailureBlock)(NSError* error);
@property (copy) void (^refreshReceiptSuccessBlock)();

@property (copy) void (^restoreTransactionsFailureBlock)(NSError* error);
@property (copy) void (^restoreTransactionsSuccessBlock)(NSArray* transactions);

@end

@implementation RMStore

- (instancetype)init
{
	self = [super init];
    if(self) {
        _addPaymentParameters = [NSMutableDictionary dictionary];
		_deferredProductIds = [NSMutableSet new];
        _products = [NSMutableDictionary dictionary];
        _productsRequestDelegates = [NSMutableSet set];
        _restoredTransactions = [NSMutableArray array];
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
    }
    return self;
}

- (void)dealloc
{
    [[SKPaymentQueue defaultQueue] removeTransactionObserver:self];
}

+ (RMStore *)defaultStore
{
    static RMStore *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[[self class] alloc] init];
    });
    return sharedInstance;
}

#pragma mark StoreKit wrapper

+ (BOOL)canMakePayments
{
    return [SKPaymentQueue canMakePayments];
}

// [NAK]
- (BOOL)isAddingPayment:(NSString*)productIdentifier
{
	return self.addPaymentParameters[productIdentifier] != nil;
}

- (BOOL)isDeferredPayment:(NSString*)productIdentifier
{
	return [self.deferredProductIds containsObject:productIdentifier];
}

- (BOOL)hasAddingPayment
{
	return self.addPaymentParameters.count > 0;
}

- (BOOL)hasDeferredPayment
{
	return self.deferredProductIds.count > 0;
}
// [NAK]

- (void)addPayment:(NSString*)productIdentifier
{
    [self addPayment:productIdentifier success:nil failure:nil];
}

- (void)addPayment:(NSString*)productIdentifier
           success:(void (^)(SKPaymentTransaction *transaction))successBlock
           failure:(void (^)(SKPaymentTransaction *transaction, NSError *error))failureBlock
{
    [self addPayment:productIdentifier user:nil success:successBlock failure:failureBlock];
}

- (void)addPayment:(NSString*)productIdentifier
              user:(NSString*)userIdentifier
           success:(void (^)(SKPaymentTransaction *transaction))successBlock
           failure:(void (^)(SKPaymentTransaction *transaction, NSError *error))failureBlock
{
	if([self isAddingPayment:productIdentifier]) { // [NAK]
		return; // [NAK] продукт в процессе покупки
	}
    SKProduct *product = [self productForIdentifier:productIdentifier];
    if (product == nil)
    {
        RMStoreLog(@"unknown product id %@", productIdentifier)
        if (failureBlock != nil)
        {
            NSError *error = [NSError errorWithDomain:RMStoreErrorDomain code:RMStoreErrorCodeUnknownProductIdentifier userInfo:@{NSLocalizedDescriptionKey: NSLocalizedStringFromTable(@"Unknown product identifier", @"RMStore", @"Error description")}];
            failureBlock(nil, error);
        }
        return;
    }
    SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:product];
    if ([payment respondsToSelector:@selector(setApplicationUsername:)])
    {
        payment.applicationUsername = userIdentifier;
    }
    
    RMAddPaymentParameters *parameters = [[RMAddPaymentParameters alloc] init];
    parameters.successBlock = successBlock;
    parameters.failureBlock = failureBlock;
    self.addPaymentParameters[productIdentifier] = parameters;
    
    [[SKPaymentQueue defaultQueue] addPayment:payment];
}

- (void)requestProducts:(NSSet*)identifiers
{
    [self requestProducts:identifiers success:nil failure:nil];
}

- (void)requestProducts:(NSSet*)identifiers
                success:(RMSKProductsRequestSuccessBlock)successBlock
                failure:(RMSKProductsRequestFailureBlock)failureBlock
{
    RMProductsRequestDelegate *delegate = [[RMProductsRequestDelegate alloc] init];
    delegate.store = self;
    delegate.successBlock = successBlock;
    delegate.failureBlock = failureBlock;
    [self.productsRequestDelegates addObject:delegate];
 
    SKProductsRequest *productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:identifiers];
	productsRequest.delegate = delegate;
    
    [productsRequest start];
}

- (void)restoreTransactions
{
    [self restoreTransactionsOnSuccess:nil failure:nil];
}

- (void)restoreTransactionsOnSuccess:(void (^)(NSArray *transactions))successBlock
                             failure:(void (^)(NSError *error))failureBlock
{
    self.restoredCompletedTransactionsFinished = NO;
    self.pendingRestoredTransactionsCount = 0;
    self.restoredTransactions = [NSMutableArray array];
    self.restoreTransactionsSuccessBlock = successBlock;
    self.restoreTransactionsFailureBlock = failureBlock;
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

- (void)restoreTransactionsOfUser:(NSString*)userIdentifier
                        onSuccess:(void (^)(NSArray *transactions))successBlock
                          failure:(void (^)(NSError *error))failureBlock
{
    NSAssert([[SKPaymentQueue defaultQueue] respondsToSelector:@selector(restoreCompletedTransactionsWithApplicationUsername:)], @"restoreCompletedTransactionsWithApplicationUsername: not supported in this iOS version. Use restoreTransactionsOnSuccess:failure: instead.");
    self.restoredCompletedTransactionsFinished = NO;
    self.pendingRestoredTransactionsCount = 0;
    self.restoreTransactionsSuccessBlock = successBlock;
    self.restoreTransactionsFailureBlock = failureBlock;
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactionsWithApplicationUsername:userIdentifier];
}

#pragma mark Receipt

+ (NSURL*)receiptURL
{
    NSURL *url = [NSBundle mainBundle].appStoreReceiptURL;
    return url;
}

- (void)refreshReceipt
{
    [self refreshReceiptOnSuccess:nil failure:nil];
}

- (void)refreshReceiptOnSuccess:(RMStoreSuccessBlock)successBlock
                        failure:(RMStoreFailureBlock)failureBlock
{
    self.refreshReceiptFailureBlock = failureBlock;
    self.refreshReceiptSuccessBlock = successBlock;
    self.refreshReceiptRequest = [[SKReceiptRefreshRequest alloc] initWithReceiptProperties:@{}];
    self.refreshReceiptRequest.delegate = self;
    [self.refreshReceiptRequest start];
}

#pragma mark Product management

- (SKProduct*)productForIdentifier:(NSString*)productIdentifier
{
    return self.products[productIdentifier];
}

+ (NSString*)localizedPriceOfProduct:(SKProduct*)product
{
	NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
	numberFormatter.numberStyle = NSNumberFormatterCurrencyStyle;
	numberFormatter.locale = product.priceLocale;
	NSString *formattedString = [numberFormatter stringFromNumber:product.price];
	return formattedString;
}

#pragma mark Observers

- (void)addStoreObserver:(id<RMStoreObserver>)observer
{
    [self addStoreObserver:observer selector:@selector(storeDownloadCanceled:) notificationName:RMSKDownloadCanceled];
    [self addStoreObserver:observer selector:@selector(storeDownloadFailed:) notificationName:RMSKDownloadFailed];
    [self addStoreObserver:observer selector:@selector(storeDownloadFinished:) notificationName:RMSKDownloadFinished];
    [self addStoreObserver:observer selector:@selector(storeDownloadPaused:) notificationName:RMSKDownloadPaused];
    [self addStoreObserver:observer selector:@selector(storeDownloadUpdated:) notificationName:RMSKDownloadUpdated];
    [self addStoreObserver:observer selector:@selector(storeProductsRequestFailed:) notificationName:RMSKProductsRequestFailed];
    [self addStoreObserver:observer selector:@selector(storeProductsRequestFinished:) notificationName:RMSKProductsRequestFinished];
    [self addStoreObserver:observer selector:@selector(storePaymentTransactionDeferred:) notificationName:RMSKPaymentTransactionDeferred];
    [self addStoreObserver:observer selector:@selector(storePaymentTransactionFailed:) notificationName:RMSKPaymentTransactionFailed];
    [self addStoreObserver:observer selector:@selector(storePaymentTransactionFinished:) notificationName:RMSKPaymentTransactionFinished];
    [self addStoreObserver:observer selector:@selector(storeRefreshReceiptFailed:) notificationName:RMSKRefreshReceiptFailed];
    [self addStoreObserver:observer selector:@selector(storeRefreshReceiptFinished:) notificationName:RMSKRefreshReceiptFinished];
    [self addStoreObserver:observer selector:@selector(storeRestoreTransactionsFailed:) notificationName:RMSKRestoreTransactionsFailed];
    [self addStoreObserver:observer selector:@selector(storeRestoreTransactionsFinished:) notificationName:RMSKRestoreTransactionsFinished];
}

- (void)removeStoreObserver:(id<RMStoreObserver>)observer
{
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKDownloadCanceled object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKDownloadFailed object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKDownloadFinished object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKDownloadPaused object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKDownloadUpdated object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKProductsRequestFailed object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKProductsRequestFinished object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKPaymentTransactionDeferred object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKPaymentTransactionFailed object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKPaymentTransactionFinished object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKRefreshReceiptFailed object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKRefreshReceiptFinished object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKRestoreTransactionsFailed object:self];
    [[NSNotificationCenter defaultCenter] removeObserver:observer name:RMSKRestoreTransactionsFinished object:self];
}

// Private

- (void)addStoreObserver:(id<RMStoreObserver>)observer selector:(SEL)aSelector notificationName:(NSString*)notificationName
{
    if ([observer respondsToSelector:aSelector])
    {
        [[NSNotificationCenter defaultCenter] addObserver:observer selector:aSelector name:notificationName object:self];
    }
}

#pragma mark SKPaymentTransactionObserver

/// ios 11 [NAK]
- (BOOL)paymentQueue:(SKPaymentQueue *)queue shouldAddStorePayment:(SKPayment *)payment forProduct:(SKProduct *)product
{
	NSString* productIdentifier = product.productIdentifier;
	if([self isAddingPayment:productIdentifier]) {
		return NO; // продукт уже покупается
	}
	if(self.shouldAddStorePaymentSuccessHandler && self.shouldAddStorePaymentFailureHandler) {
		RMAddPaymentParameters *parameters = [[RMAddPaymentParameters alloc] init];
		parameters.successBlock = self.shouldAddStorePaymentSuccessHandler;
		parameters.failureBlock = self.shouldAddStorePaymentFailureHandler;
		self.addPaymentParameters[productIdentifier] = parameters;
		return YES;
	}
	return NO;
}
- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions
{
    for (SKPaymentTransaction *transaction in transactions)
    {
        switch (transaction.transactionState)
        {
            case SKPaymentTransactionStatePurchased:
                [self didPurchaseTransaction:transaction queue:queue];
                break;
            case SKPaymentTransactionStateFailed:
                [self didFailTransaction:transaction queue:queue error:transaction.error];
                break;
            case SKPaymentTransactionStateRestored:
                [self didRestoreTransaction:transaction queue:queue];
                break;
            case SKPaymentTransactionStateDeferred:
                [self didDeferTransaction:transaction];
                break;
			case SKPaymentTransactionStatePurchasing:
				break;
            default:
                break;
        }
    }
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue
{
    RMStoreLog(@"restore transactions finished");
    self.restoredCompletedTransactionsFinished = YES;
    
    [self notifyRestoreTransactionFinishedIfApplicableAfterTransaction:nil];
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error
{
    RMStoreLog(@"restored transactions failed with error %@", error.debugDescription);
    if (self.restoreTransactionsFailureBlock != nil)
    {
        self.restoreTransactionsFailureBlock(error);
        self.restoreTransactionsFailureBlock = nil;
    }
    NSDictionary *userInfo = nil;
    if (error)
    { // error might be nil (e.g., on airplane mode)
        userInfo = @{RMStoreNotificationStoreError: error};
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RMSKRestoreTransactionsFailed object:self userInfo:userInfo];
}

- (void)paymentQueue:(SKPaymentQueue *)queue updatedDownloads:(NSArray *)downloads
{
    for (SKDownload *download in downloads)
    {
        switch (download.downloadState)
        {
            case SKDownloadStateActive:
                [self didUpdateDownload:download queue:queue];
                break;
            case SKDownloadStateCancelled:
                [self didCancelDownload:download queue:queue];
                break;
            case SKDownloadStateFailed:
                [self didFailDownload:download queue:queue];
                break;
            case SKDownloadStateFinished:
                [self didFinishDownload:download queue:queue];
                break;
            case SKDownloadStatePaused:
                [self didPauseDownload:download queue:queue];
                break;
            case SKDownloadStateWaiting:
                // Do nothing
                break;
        }
    }
}

- (void)paymentQueue:(SKPaymentQueue *)queue removedTransactions:(NSArray <SKPaymentTransaction *> *)transactions
{
	RMStoreLog(@"removed transactions %@", transactions);
}

#pragma mark Download State

- (void)didCancelDownload:(SKDownload*)download queue:(SKPaymentQueue*)queue
{
    SKPaymentTransaction *transaction = download.transaction;
    RMStoreLog(@"download %@ for product %@ canceled", download.contentIdentifier, download.transaction.payment.productIdentifier);

    [self postNotificationWithName:RMSKDownloadCanceled download:download userInfoExtras:nil];

    NSError *error = [NSError errorWithDomain:RMStoreErrorDomain code:RMStoreErrorCodeDownloadCanceled userInfo:@{NSLocalizedDescriptionKey: NSLocalizedStringFromTable(@"Download canceled", @"RMStore", @"Error description")}];

    const BOOL hasPendingDownloads = [self.class hasPendingDownloadsInTransaction:transaction];
    if (!hasPendingDownloads)
    {
        [self didFailTransaction:transaction queue:queue error:error];
    }
}

- (void)didFailDownload:(SKDownload*)download queue:(SKPaymentQueue*)queue
{
    NSError *error = download.error;
    SKPaymentTransaction *transaction = download.transaction;
    RMStoreLog(@"download %@ for product %@ failed with error %@", download.contentIdentifier, transaction.payment.productIdentifier, error.debugDescription);

    NSDictionary *extras = error ? @{RMStoreNotificationStoreError : error} : nil;
    [self postNotificationWithName:RMSKDownloadFailed download:download userInfoExtras:extras];

    const BOOL hasPendingDownloads = [self.class hasPendingDownloadsInTransaction:transaction];
    if (!hasPendingDownloads)
    {
        [self didFailTransaction:transaction queue:queue error:error];
    }
}

- (void)didFinishDownload:(SKDownload*)download queue:(SKPaymentQueue*)queue
{
    SKPaymentTransaction *transaction = download.transaction;
    RMStoreLog(@"download %@ for product %@ finished", download.contentIdentifier, transaction.payment.productIdentifier);
    
    [self postNotificationWithName:RMSKDownloadFinished download:download userInfoExtras:nil];

    const BOOL hasPendingDownloads = [self.class hasPendingDownloadsInTransaction:transaction];
    if (!hasPendingDownloads)
    {
        [self finishTransaction:download.transaction queue:queue];
    }
}

- (void)didPauseDownload:(SKDownload*)download queue:(SKPaymentQueue*)queue
{
    RMStoreLog(@"download %@ for product %@ paused", download.contentIdentifier, download.transaction.payment.productIdentifier);
    [self postNotificationWithName:RMSKDownloadPaused download:download userInfoExtras:nil];
}

- (void)didUpdateDownload:(SKDownload*)download queue:(SKPaymentQueue*)queue
{
    RMStoreLog(@"download %@ for product %@ updated", download.contentIdentifier, download.transaction.payment.productIdentifier);
    NSDictionary *extras = @{RMStoreNotificationDownloadProgress : @(download.progress)};
    [self postNotificationWithName:RMSKDownloadUpdated download:download userInfoExtras:extras];
}

+ (BOOL)hasPendingDownloadsInTransaction:(SKPaymentTransaction*)transaction
{
    for (SKDownload *download in transaction.downloads)
    {
        switch (download.downloadState)
        {
            case SKDownloadStateActive:
            case SKDownloadStatePaused:
            case SKDownloadStateWaiting:
                return YES;
            case SKDownloadStateCancelled:
            case SKDownloadStateFailed:
            case SKDownloadStateFinished:
                continue;
        }
    }
    return NO;
}

#pragma mark Transaction State

- (void)didPurchaseTransaction:(SKPaymentTransaction *)transaction queue:(SKPaymentQueue*)queue
{
    RMStoreLog(@"transaction purchased with product %@", transaction.payment.productIdentifier);
    
    if (self.receiptVerifier != nil)
    {
        [self.receiptVerifier verifyTransaction:transaction success:^{
            [self didVerifyTransaction:transaction queue:queue];
        } failure:^(NSError *error) {
            [self didFailTransaction:transaction queue:queue error:error];
        }];
    }
    else
    {
        RMStoreLog(@"WARNING: no receipt verification");
        [self didVerifyTransaction:transaction queue:queue];
    }
}

- (void)didFailTransaction:(SKPaymentTransaction *)transaction queue:(SKPaymentQueue*)queue error:(NSError*)error
{
    SKPayment *payment = transaction.payment;
	NSString* productIdentifier = payment.productIdentifier;
    RMStoreLog(@"transaction failed with product %@ and error %@", productIdentifier, error.debugDescription);
    
    if (error.code != RMStoreErrorCodeUnableToCompleteVerification)
    { // If we were unable to complete the verification we want StoreKit to keep reminding us of the transaction
        [queue finishTransaction:transaction];
    }
    
    RMAddPaymentParameters *parameters = [self popAddPaymentParametersForIdentifier:productIdentifier];
    if (parameters.failureBlock != nil)
    {
        parameters.failureBlock(transaction, error);
    }
    
    NSDictionary *extras = error ? @{RMStoreNotificationStoreError : error} : nil;
    [self postNotificationWithName:RMSKPaymentTransactionFailed transaction:transaction userInfoExtras:extras];
    
    if (transaction.transactionState == SKPaymentTransactionStateRestored)
    {
        [self notifyRestoreTransactionFinishedIfApplicableAfterTransaction:transaction];
    }
}

- (void)didRestoreTransaction:(SKPaymentTransaction *)transaction queue:(SKPaymentQueue*)queue
{
    RMStoreLog(@"transaction restored with product %@", transaction.originalTransaction.payment.productIdentifier);
    
    self.pendingRestoredTransactionsCount++;
    if (self.receiptVerifier != nil)
    {
        [self.receiptVerifier verifyTransaction:transaction success:^{
            [self didVerifyTransaction:transaction queue:queue];
        } failure:^(NSError *error) {
            [self didFailTransaction:transaction queue:queue error:error];
        }];
    }
    else
    {
        RMStoreLog(@"WARNING: no receipt verification");
        [self didVerifyTransaction:transaction queue:queue];
    }
}

- (void)didDeferTransaction:(SKPaymentTransaction *)transaction
{
	NSString* productId = transaction.payment.productIdentifier;
	if(productId) {
		[self.deferredProductIds addObject:productId];
	}
    [self postNotificationWithName:RMSKPaymentTransactionDeferred transaction:transaction userInfoExtras:nil];
}

- (void)didVerifyTransaction:(SKPaymentTransaction *)transaction queue:(SKPaymentQueue*)queue
{
    if (self.contentDownloader != nil)
    {
        [self.contentDownloader downloadContentForTransaction:transaction success:^{
            [self postNotificationWithName:RMSKDownloadFinished transaction:transaction userInfoExtras:nil];
            [self didDownloadSelfHostedContentForTransaction:transaction queue:queue];
        } progress:^(float progress) {
            NSDictionary *extras = @{RMStoreNotificationDownloadProgress : @(progress)};
            [self postNotificationWithName:RMSKDownloadUpdated transaction:transaction userInfoExtras:extras];
        } failure:^(NSError *error) {
            NSDictionary *extras = error ? @{RMStoreNotificationStoreError : error} : nil;
            [self postNotificationWithName:RMSKDownloadFailed transaction:transaction userInfoExtras:extras];
            [self didFailTransaction:transaction queue:queue error:error];
        }];
    }
    else
    {
        [self didDownloadSelfHostedContentForTransaction:transaction queue:queue];
    }
}

- (void)didDownloadSelfHostedContentForTransaction:(SKPaymentTransaction *)transaction queue:(SKPaymentQueue*)queue
{
    NSArray *downloads = [transaction respondsToSelector:@selector(downloads)] ? transaction.downloads : @[];
    if (downloads.count > 0)
    {
        RMStoreLog(@"starting downloads for product %@ started", transaction.payment.productIdentifier);
        [queue startDownloads:downloads];
    }
    else
    {
        [self finishTransaction:transaction queue:queue];
    }
}

- (void)finishTransaction:(SKPaymentTransaction *)transaction queue:(SKPaymentQueue*)queue
{
    SKPayment *payment = transaction.payment;
	NSString* productIdentifier = payment.productIdentifier;
    [queue finishTransaction:transaction];
    [self.transactionPersistor persistTransaction:transaction];
    
    RMAddPaymentParameters *wrapper = [self popAddPaymentParametersForIdentifier:productIdentifier];
    if (wrapper.successBlock != nil)
    {
        wrapper.successBlock(transaction);
    }
    
    [self postNotificationWithName:RMSKPaymentTransactionFinished transaction:transaction userInfoExtras:nil];
    
    if (transaction.transactionState == SKPaymentTransactionStateRestored)
    {
        [self notifyRestoreTransactionFinishedIfApplicableAfterTransaction:transaction];
    }
}

- (void)notifyRestoreTransactionFinishedIfApplicableAfterTransaction:(SKPaymentTransaction*)transaction
{
    if (transaction != nil)
    {
        [self.restoredTransactions addObject:transaction];
        self.pendingRestoredTransactionsCount--;
    }
    if (self.restoredCompletedTransactionsFinished && self.pendingRestoredTransactionsCount == 0)
    { // Wait until all restored transations have been verified
        NSArray *restoredTransactions = [self.restoredTransactions copy];
        if (self.restoreTransactionsSuccessBlock != nil)
        {
            self.restoreTransactionsSuccessBlock(restoredTransactions);
            self.restoreTransactionsSuccessBlock = nil;
        }
        NSDictionary *userInfo = @{ RMStoreNotificationTransactions : restoredTransactions };
        [[NSNotificationCenter defaultCenter] postNotificationName:RMSKRestoreTransactionsFinished object:self userInfo:userInfo];
    }
}

- (RMAddPaymentParameters*)popAddPaymentParametersForIdentifier:(NSString*)identifier
{
    RMAddPaymentParameters *parameters = self.addPaymentParameters[identifier];
    [self.addPaymentParameters removeObjectForKey:identifier];
	[self.deferredProductIds removeObject:identifier];
    return parameters;
}

#pragma mark SKRequestDelegate

- (void)requestDidFinish:(SKRequest *)request
{
    RMStoreLog(@"refresh receipt finished");
    self.refreshReceiptRequest = nil;
    if (self.refreshReceiptSuccessBlock)
    {
        self.refreshReceiptSuccessBlock();
        self.refreshReceiptSuccessBlock = nil;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RMSKRefreshReceiptFinished object:self];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error
{
    RMStoreLog(@"refresh receipt failed with error %@", error.debugDescription);
    self.refreshReceiptRequest = nil;
    if (self.refreshReceiptFailureBlock)
    {
        self.refreshReceiptFailureBlock(error);
        self.refreshReceiptFailureBlock = nil;
    }
    NSDictionary *userInfo = nil;
    if (error)
    { // error might be nil (e.g., on airplane mode)
        userInfo = @{RMStoreNotificationStoreError: error};
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RMSKRefreshReceiptFailed object:self userInfo:userInfo];
}

#pragma mark Private

- (void)addProduct:(SKProduct*)product
{
    self.products[product.productIdentifier] = product;
}

- (void)postNotificationWithName:(NSString*)notificationName download:(SKDownload*)download userInfoExtras:(NSDictionary*)extras
{
    NSMutableDictionary *mutableExtras = extras ? [NSMutableDictionary dictionaryWithDictionary:extras] : [NSMutableDictionary dictionary];
    mutableExtras[RMStoreNotificationStoreDownload] = download;
    [self postNotificationWithName:notificationName transaction:download.transaction userInfoExtras:mutableExtras];
}

- (void)postNotificationWithName:(NSString*)notificationName transaction:(SKPaymentTransaction*)transaction userInfoExtras:(NSDictionary*)extras
{
    NSString *productIdentifier = transaction.payment.productIdentifier;
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[RMStoreNotificationTransaction] = transaction;
    userInfo[RMStoreNotificationProductIdentifier] = productIdentifier;
    if (extras)
    {
        [userInfo addEntriesFromDictionary:extras];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self userInfo:userInfo];
}

- (void)removeProductsRequestDelegate:(RMProductsRequestDelegate*)delegate
{
    [self.productsRequestDelegates removeObject:delegate];
}

@end

@implementation RMProductsRequestDelegate

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response
{
    RMStoreLog(@"products request received response");
    NSArray *products = [NSArray arrayWithArray:response.products];
    NSArray *invalidProductIdentifiers = [NSArray arrayWithArray:response.invalidProductIdentifiers];
    
    for (SKProduct *product in products)
    {
        RMStoreLog(@"received product with id %@", product.productIdentifier);
        [self.store addProduct:product];
    }
    
    [invalidProductIdentifiers enumerateObjectsUsingBlock:^(NSString *invalid, NSUInteger idx, BOOL *stop) {
        RMStoreLog(@"invalid product with id %@", invalid);
    }];
    
    if (self.successBlock)
    {
        self.successBlock(products, invalidProductIdentifiers);
    }
    NSDictionary *userInfo = @{RMStoreNotificationProducts: products, RMStoreNotificationInvalidProductIdentifiers: invalidProductIdentifiers};
    [[NSNotificationCenter defaultCenter] postNotificationName:RMSKProductsRequestFinished object:self.store userInfo:userInfo];
}

- (void)requestDidFinish:(SKRequest *)request
{
    [self.store removeProductsRequestDelegate:self];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error
{
    RMStoreLog(@"products request failed with error %@", error.debugDescription);
    if (self.failureBlock)
    {
        self.failureBlock(error);
    }
    NSDictionary *userInfo = nil;
    if (error)
    { // error might be nil (e.g., on airplane mode)
        userInfo = @{RMStoreNotificationStoreError: error};
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RMSKProductsRequestFailed object:self.store userInfo:userInfo];
    [self.store removeProductsRequestDelegate:self];
}

@end
