/* Copyright © 2007-2008, The Sequential Project
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the the Sequential Project nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE SEQUENTIAL PROJECT ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE SEQUENTIAL PROJECT BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. */
#import "PGNode.h"

// Models
#import "PGDocument.h"
#import "PGResourceAdapter.h"
#import "PGErrorAdapter.h"
#import "PGContainerAdapter.h"
#import "PGResourceIdentifier.h"
#import "PGBookmark.h"

// Categories
#import "NSDateAdditions.h"
#import "NSMutableDictionaryAdditions.h"
#import "NSNumberAdditions.h"
#import "NSObjectAdditions.h"
#import "NSStringAdditions.h"

NSString *const PGNodeLoadingDidProgressNotification = @"PGNodeLoadingDidProgress";
NSString *const PGNodeReadyForViewingNotification    = @"PGNodeReadyForViewing";

NSString *const PGImageRepKey       = @"PGImageRep";
NSString *const PGErrorKey          = @"PGError";

NSString *const PGNodeErrorDomain        = @"PGNodeError";
NSString *const PGUnencodedStringDataKey = @"PGUnencodedStringData";
NSString *const PGDefaultEncodingKey     = @"PGDefaultEncoding";

enum {
	PGNodeNothing               = 0,
	PGNodeLoading               = 1 << 0,
	PGNodeReading               = 1 << 1,
	PGNodeLoadingOrReading      = PGNodeLoading | PGNodeReading
}; // PGNodeStatus.

@interface PGNode (Private)

- (void)_setResourceAdapter:(PGResourceAdapter *)adapter;
- (NSArray *)_standardizedInfo:(id)info;
- (NSDictionary *)_standardizedInfoDictionary:(NSDictionary *)info;
- (void)_updateMenuItem;
- (void)_updateFileAttributes;

@end

@implementation PGNode

#pragma mark NSObject

+ (void)initialize
{
	srandom(time(NULL)); // Used by our shuffle sort.
}

#pragma mark Instance Methods

- (id)initWithParentAdapter:(PGContainerAdapter *)parent
      document:(PGDocument *)doc
      identifier:(PGDisplayableIdentifier *)ident
      dataSource:(id)dataSource
{
	if(!(self = [super init])) return nil;
	NSParameterAssert(!parent != !doc);
	if(!ident) {
		[self release];
		return nil;
	}
	_parentAdapter = parent;
	_document = doc;
	_identifier = [ident retain];
	_dataSource = dataSource;
	PGResourceAdapter *const adapter = [[[PGResourceAdapter alloc] init] autorelease];
	_adapters = [[NSMutableArray alloc] initWithObjects:adapter, nil];
	[self _setResourceAdapter:adapter];
	_menuItem = [[NSMenuItem alloc] init];
	[_menuItem setRepresentedObject:[NSValue valueWithNonretainedObject:self]];
	[_menuItem setAction:@selector(jumpToPage:)];
	_allowMenuItemUpdates = YES;
	[self _updateMenuItem];
	[_identifier AE_addObserver:self selector:@selector(identifierIconDidChange:) name:PGDisplayableIdentifierIconDidChangeNotification];
	[_identifier AE_addObserver:self selector:@selector(identifierDisplayNameDidChange:) name:PGDisplayableIdentifierDisplayNameDidChangeNotification];
	return self;
}

#pragma mark -

- (id)dataSource
{
	return _dataSource;
}
- (NSData *)dataWithInfo:(NSDictionary *)info
            fast:(BOOL)flag
{
	NSData *data = [[[info objectForKey:PGDataKey] retain] autorelease];
	if(data) return data;
	@synchronized(self) {
		if([self dataSource] && ![[self dataSource] node:self getData:&data info:info fast:flag]) return nil;
	}
	if(data) return data;
	PGResourceIdentifier *const identifier = [info objectForKey:PGIdentifierKey];
	if([identifier isFileIdentifier]) data = [NSData dataWithContentsOfMappedFile:[[identifier URLByFollowingAliases:YES] path]];
	return data;
}
- (BOOL)canGetDataWithInfo:(NSDictionary *)info
{
	return [self dataSource] || [info objectForKey:PGFourCCDataKey] || [info objectForKey:PGDataKey] || [[info objectForKey:PGIdentifierKey] isFileIdentifier];
}

#pragma mark -

- (PGResourceAdapter *)resourceAdapter
{
	return [[_adapter retain] autorelease];
}
- (PGLoadPolicy)ancestorLoadPolicy
{
	PGContainerAdapter *const p = [self parentAdapter];
	return p ? MAX([[p node] ancestorLoadPolicy], [p descendentLoadPolicy]) : PGLoadToMaxDepth;
}
- (BOOL)shouldLoadAdapterClass:(Class)aClass
{
	if([aClass alwaysLoads]) return YES;
	switch([self ancestorLoadPolicy]) {
		case PGLoadToMaxDepth: return [self depth] <= [[[NSUserDefaults standardUserDefaults] objectForKey:PGMaxDepthKey] unsignedIntValue];
		case PGLoadAll: return YES;
		default: return NO;
	}
}
- (void)startLoadWithInfo:(id)info
{
	NSParameterAssert(!(PGNodeLoading & _status));
	_status |= PGNodeLoading;
	[_error release];
	_error = nil;
	[self noteIsViewableDidChange];
	[_adapters autorelease];
	_adapters = [[PGResourceAdapter adapterClassesInstantiated:YES forNode:self withInfoDicts:[self _standardizedInfo:info]] mutableCopy];
	[_adapters insertObject:[[[PGErrorAdapter alloc] init] autorelease] atIndex:0];
	[self _setResourceAdapter:[_adapters lastObject]];
	[_adapter loadIfNecessary];
}
- (void)continueLoadWithInfo:(id)info
{
	NSParameterAssert(PGNodeLoading & _status);
	NSParameterAssert(info && [info count]); // Otherwise nothing has changed.
	NSArray *const newAdapters = [PGResourceAdapter adapterClassesInstantiated:YES forNode:self withInfoDicts:[self _standardizedInfo:info]];
	if(![newAdapters count]) return [_adapter fallbackLoad];
	[_adapters addObjectsFromArray:newAdapters];
	NSParameterAssert([_adapters count]);
	[self _setResourceAdapter:[_adapters lastObject]];
	[_adapter loadIfNecessary];
}
- (void)loadFinished
{
	NSParameterAssert(PGNodeLoading & _status);
	_status &= ~PGNodeLoading;
	[self noteIsViewableDidChange];
	[self _updateFileAttributes];
	[self readIfNecessary];
	[[self document] noteNodeThumbnailDidChange:self children:NO];
}

#pragma mark -

- (void)becomeViewed
{
	[[self parentLoad] prioritizeSubload:self];
	if(PGNodeReading & _status) return;
	_status |= PGNodeReading;
	[self readIfNecessary];
}
- (void)readIfNecessary
{
	if((PGNodeLoadingOrReading & _status) == PGNodeReading) [_adapter read];
}
- (void)readFinishedWithImageRep:(NSImageRep *)aRep
        error:(NSError *)error
{
	NSParameterAssert((PGNodeLoadingOrReading & _status) == PGNodeReading);
	_status &= ~PGNodeReading;
	NSMutableDictionary *const dict = [NSMutableDictionary dictionary];
	[dict AE_setObject:aRep forKey:PGImageRepKey];
	if(error) [dict setObject:error forKey:PGErrorKey];
	else {
		[dict AE_setObject:_error forKey:PGErrorKey];
		[_error release];
		_error = nil;
	}
	[self AE_postNotificationName:PGNodeReadyForViewingNotification userInfo:dict];
}

#pragma mark -

- (NSError *)error
{
	return [[_error retain] autorelease];
}
- (void)setError:(NSError *)error
{
	if(PGNodeNothing == _status) return;
	if(!_error) {
		_error = [error copy];
		_errorPhase = _status;
	}
	if(PGNodeLoading & _status && [_adapters count] > 1) {
		(void)[[[_adapters lastObject] retain] autorelease];
		if([_adapter shouldFallbackOnError]) [_adapters removeLastObject];
		else [_adapters removeObjectsInRange:NSMakeRange(1, [_adapters count] - 1)];
		[self _setResourceAdapter:[_adapters lastObject]];
		[_adapter fallbackLoad];
	}
}

#pragma mark -

- (NSImage *)thumbnail
{
	return PGNodeLoading & _status ? nil : [[self resourceAdapter] thumbnail];
}

#pragma mark -

- (BOOL)isViewable
{
	return _viewable;
}
- (unsigned)depth
{
	return [self parentNode] ? [[self parentNode] depth] + 1 : 0;
}
- (PGNode *)viewableAncestor
{
	return _viewable ? self : [[self parentNode] viewableAncestor];
}
- (NSMenuItem *)menuItem
{
	return [[_menuItem retain] autorelease];
}

#pragma mark -

- (void)removeFromDocument
{
	if([[self document] node] == self) [[self document] close];
	else [[self parentAdapter] removeChild:self];
}
- (void)detachFromTree
{
	@synchronized(self) {
		_parentAdapter = nil;
		_document = nil;
		_dataSource = nil;
	}
}

#pragma mark -

- (NSDate *)dateModified
{
	return _dateModified ? [[_dateModified retain] autorelease] : [NSDate distantPast];
}
- (NSDate *)dateCreated
{
	return _dateCreated ? [[_dateCreated retain] autorelease] : [NSDate distantPast];
}
- (NSNumber *)dataLength
{
	return _dataLength ? [[_dataLength retain] autorelease] : [NSNumber numberWithUnsignedInt:0];
}
- (NSComparisonResult)compare:(PGNode *)node
{
	NSParameterAssert(node);
	NSParameterAssert([self document]);
	PGSortOrder const o = [[self document] sortOrder];
	int const d = PGSortDescendingMask & o ? -1 : 1;
	NSComparisonResult r = NSOrderedSame;
	switch(PGSortOrderMask & o) {
		case PGUnsorted:           return NSOrderedSame;
		case PGSortByDateModified: r = [[self dateModified] compare:[node dateModified]]; break;
		case PGSortByDateCreated:  r = [[self dateCreated] compare:[node dateCreated]]; break;
		case PGSortBySize:         r = [[self dataLength] compare:[node dataLength]]; break;
		case PGSortShuffle:        return random() & 1 ? NSOrderedAscending : NSOrderedDescending;
	}
	return (NSOrderedSame == r ? [[[self identifier] displayName] AE_localizedCaseInsensitiveNumericCompare:[[node identifier] displayName]] : r) * d; // If the actual sort order doesn't produce a distinct ordering, then sort by name too.
}

#pragma mark -

- (BOOL)canBookmark
{
	return [self isViewable] && [[self identifier] hasTarget];
}
- (PGBookmark *)bookmark
{
	return [[[PGBookmark alloc] initWithNode:self] autorelease];
}

#pragma mark -

- (void)identifierIconDidChange:(NSNotification *)aNotif
{
	[self _updateMenuItem];
}
- (void)identifierDisplayNameDidChange:(NSNotification *)aNotif
{
	[self _updateMenuItem];
	[[self parentAdapter] noteChild:self didChangeForSortOrder:PGSortByName];
	[[self document] noteNodeDisplayNameDidChange:self];
}

#pragma mark Private Protocol

- (void)_setResourceAdapter:(PGResourceAdapter *)adapter
{
	if(adapter == _adapter) return;
	if([_adapter node] == self) [_adapter setNode:nil];
	_adapter = adapter;
	[_adapter setNode:self];
	[self _updateMenuItem];
}
- (NSArray *)_standardizedInfo:(id)info
{
	NSMutableArray *const results = [NSMutableArray array];
	NSDictionary *dict;
	NSEnumerator *const dictEnum = [[info AE_asArray] objectEnumerator];
	while((dict = [dictEnum nextObject])) [results addObject:[self _standardizedInfoDictionary:dict]];
	if(![results count]) [results addObject:[self _standardizedInfoDictionary:nil]];
	return results;
}
- (NSDictionary *)_standardizedInfoDictionary:(NSDictionary *)info
{
	NSMutableDictionary *const mutableInfo = info ? [[info mutableCopy] autorelease] : [NSMutableDictionary dictionary];
	[[self dataSource] node:self willLoadWithInfo:mutableInfo];
	NSURLResponse *const response = [info objectForKey:PGURLResponseKey];
	if(![mutableInfo objectForKey:PGIdentifierKey]) {
		NSURL *const responseURL = [response URL];
		[mutableInfo AE_setObject:(responseURL ? [responseURL PG_resourceIdentifier] : [self identifier]) forKey:PGIdentifierKey];
	}
	if(![mutableInfo objectForKey:PGMIMETypeKey]) [mutableInfo AE_setObject:[response MIMEType] forKey:PGMIMETypeKey];
	if(![mutableInfo objectForKey:PGExtensionKey]) [mutableInfo AE_setObject:[[[[mutableInfo objectForKey:PGIdentifierKey] URL] path] pathExtension] forKey:PGExtensionKey];
	if(![mutableInfo objectForKey:PGFourCCDataKey]) {
		NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
		NSData *const data = [self dataWithInfo:mutableInfo fast:YES];
		if(data && [data length] >= 4) [mutableInfo AE_setObject:[data subdataWithRange:NSMakeRange(0, 4)] forKey:PGFourCCDataKey];
		[pool release]; // Dispose of the data ASAP.
	}
	[mutableInfo setObject:[NSNumber numberWithInt:([self canGetDataWithInfo:mutableInfo] ? PGExists : PGDoesNotExist)] forKey:PGDataExistenceKey];
	return mutableInfo;
}
- (void)_updateMenuItem
{
	if(!_allowMenuItemUpdates) return;
	NSMutableAttributedString *const label = [[[[self identifier] attributedStringWithWithAncestory:NO] mutableCopy] autorelease];
	NSString *info = nil;
	NSDate *date = nil;
	switch(PGSortOrderMask & [[self document] sortOrder]) {
		case PGSortByDateModified: date = _dateModified; break;
		case PGSortByDateCreated:  date = _dateCreated; break;
		case PGSortBySize: info = [_dataLength AE_localizedStringAsBytes]; break;
	}
	if(date && !info) info = [date AE_localizedStringWithDateStyle:kCFDateFormatterShortStyle timeStyle:kCFDateFormatterShortStyle];
	if(info) [label appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" (%@)", info] attributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSColor grayColor], NSForegroundColorAttributeName, [NSFont boldSystemFontOfSize:12], NSFontAttributeName, nil]] autorelease]];
	[_menuItem setAttributedTitle:label];
}
- (void)_updateFileAttributes
{
	BOOL menuNeedsUpdate = NO;
	NSString *path = nil;
	NSDictionary *attributes = nil;
	NSDate *dateModified = [[self dataSource] dateModifiedForNode:self];
	if(!dateModified) {
		PGResourceIdentifier *const identifier = [self identifier];
		if(path || [identifier isFileIdentifier]) {
			if(!path) path = [[identifier URL] path];
			if(!attributes) attributes = [[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:NO];
			dateModified = [attributes fileModificationDate];
		}
	}
	if(_dateModified != dateModified && (!_dateModified || !dateModified || ![_dateModified isEqualToDate:dateModified])) {
		[_dateModified release];
		_dateModified = [dateModified retain];
		[[self parentAdapter] noteChild:self didChangeForSortOrder:PGSortByDateModified];
		menuNeedsUpdate = YES;
	}
	NSDate *dateCreated = [[self dataSource] dateCreatedForNode:self];
	if(!dateCreated) {
		PGResourceIdentifier *const identifier = [self identifier];
		if(path || [identifier isFileIdentifier]) {
			if(!path) path = [[identifier URL] path];
			if(!attributes) attributes = [[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:NO];
			dateCreated = [attributes fileCreationDate];
		}
	}
	if(_dateCreated != dateCreated && (!_dateCreated || !dateCreated || ![_dateCreated isEqualToDate:dateCreated])) {
		[_dateCreated release];
		_dateCreated = [dateCreated retain];
		[[self parentAdapter] noteChild:self didChangeForSortOrder:PGSortByDateCreated];
		menuNeedsUpdate = YES;
	}
	NSNumber *dataLength = [[self dataSource] dataLengthForNode:self];
	do {
		if(dataLength) break;
		NSData *const data = [self data];
		if(data) dataLength = [NSNumber numberWithUnsignedInt:[data length]];
		if(dataLength) break;
		PGResourceIdentifier *const identifier = [self identifier];
		if(path || [identifier isFileIdentifier]) {
			if(!path) path = [[identifier URL] path];
			if(!attributes) attributes = [[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:NO];
			if(![NSFileTypeDirectory isEqualToString:[attributes fileType]]) dataLength = [attributes objectForKey:NSFileSize]; // File size is meaningless for folders.
		}
	} while(NO);
	if(_dataLength != dataLength && (!_dataLength || !dataLength || ![_dataLength isEqualToNumber:dataLength])) {
		[_dataLength release];
		_dataLength = [dataLength retain];
		[[self parentAdapter] noteChild:self didChangeForSortOrder:PGSortBySize];
		menuNeedsUpdate = YES;
	}
	if(menuNeedsUpdate) [self _updateMenuItem];
}

#pragma mark PGResourceAdapting Proxy

- (PGNode *)parentNode
{
	return [_parentAdapter node];
}
- (PGContainerAdapter *)parentAdapter
{
	return _parentAdapter;
}
- (PGNode *)rootNode
{
	return [self parentNode] ? [[self parentNode] rootNode] : self;
}
- (PGDocument *)document
{
	return _document ? _document : [_parentAdapter document];
}

#pragma mark -

- (PGDisplayableIdentifier *)identifier
{
	return [[_identifier retain] autorelease];
}

#pragma mark -

- (void)noteFileEventDidOccurDirect:(BOOL)flag
{
	[[self identifier] updateNaturalDisplayName];
	[self _updateFileAttributes];
	[_adapter noteFileEventDidOccurDirect:flag];
}
- (void)noteSortOrderDidChange
{
	[self _updateMenuItem];
	[_adapter noteSortOrderDidChange];
}
- (void)noteIsViewableDidChange
{
	BOOL const flag = PGNodeLoading & _status || (_error && (PGNodeLoadingOrReading & _errorPhase) == PGNodeReading) || [_adapter adapterIsViewable]; // If we're loading, we should display a loading indicator, meaning we must be viewable.
	if(flag == _viewable) return;
	_viewable = flag;
	[[self document] noteNodeIsViewableDidChange:self];
}

#pragma mark NSObject Protocol

- (unsigned)hash
{
	return [[self class] hash] ^ [[self identifier] hash];
}
- (BOOL)isEqual:(id)anObject
{
	return [anObject isMemberOfClass:[self class]] && [[self identifier] isEqual:[anObject identifier]];
}

#pragma mark -

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@(%@) %p: %@>", [self class], [_adapter class], self, [self identifier]];
}

#pragma mark -

- (BOOL)respondsToSelector:(SEL)sel
{
	return [super respondsToSelector:sel] ? YES : [_adapter respondsToSelector:sel];
}

#pragma mark NSObject

- (void)dealloc
{
	[self AE_removeObserver];
	[_adapter setNode:nil]; // PGGenericImageAdapter gets retained while it's loading in another thread, and when it finishes it might expect us to still be around.
	[_identifier release];
	[_menuItem release];
	[_adapters release];
	[_error release];
	[_dateModified release];
	[_dateCreated release];
	[_dataLength release];
	[super dealloc];
}

#pragma mark -

- (IMP)methodForSelector:(SEL)sel
{
	return [super respondsToSelector:sel] ? [super methodForSelector:sel] : [_adapter methodForSelector:sel];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	return [_adapter methodSignatureForSelector:sel];
}
- (void)forwardInvocation:(NSInvocation *)invocation
{
	[invocation invokeWithTarget:_adapter];
}

@end

@implementation NSObject (PGNodeDataSource)

- (NSDate *)dateModifiedForNode:(PGNode *)sender
{
	return nil;
}
- (NSDate *)dateCreatedForNode:(PGNode *)sender
{
	return nil;
}
- (NSNumber *)dataLengthForNode:(PGNode *)sender
{
	return nil;
}
- (void)node:(PGNode *)sender willLoadWithInfo:(NSMutableDictionary *)info {}
- (BOOL)node:(PGNode *)sender
        getData:(out NSData **)outData
        info:(NSDictionary *)info
        fast:(BOOL)flag
{
	if(outData) *outData = nil;
	return YES;
}

@end
