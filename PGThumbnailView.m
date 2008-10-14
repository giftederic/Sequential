/* Copyright © 2007-2008 The Sequential Project. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal with the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:
1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimers.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimers in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of The Sequential Project nor the names of its
   contributors may be used to endorse or promote products derived from
   this Software without specific prior written permission.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
THE CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS WITH THE SOFTWARE. */
#import "PGThumbnailView.h"

// Views
#import "PGClipView.h"

// Categories
#import "NSBezierPathAdditions.h"

#define PGThumbnailSize      48.0
#define PGThumbnailMargin    8.0
#define PGThumbnailSizeTotal (PGThumbnailSize + PGThumbnailMargin)

@implementation PGThumbnailView

#pragma mark Instance Methods

- (id)dataSource
{
	return dataSource;
}
- (void)setDataSource:(id)obj
{
	dataSource = obj;
}
- (id)delegate
{
	return delegate;
}
- (void)setDelegate:(id)obj
{
	delegate = obj;
}
- (id)representedObject
{
	return [[_representedObject retain] autorelease];
}
- (void)setRepresentedObject:(id)obj
{
	if(obj == _representedObject) return;
	[_representedObject release];
	_representedObject = [obj retain];
}

#pragma mark -

- (NSSet *)selection
{
	return [[_selection copy] autorelease];
}

#pragma mark -

- (unsigned)numberOfColumns
{
	return _numberOfColumns;
}
- (unsigned)indexOfItemAtPoint:(NSPoint)p
{
	return floorf((p.y - PGThumbnailMargin) / PGThumbnailSizeTotal) * _numberOfColumns + floorf((p.x - PGThumbnailMargin) / PGThumbnailSizeTotal);
}
- (NSRect)frameOfItemAtIndex:(unsigned)index
          withMargin:(BOOL)flag
{
	NSRect const frame = NSMakeRect((index % _numberOfColumns) * PGThumbnailSizeTotal + PGThumbnailMargin, (index / _numberOfColumns) * PGThumbnailSizeTotal + PGThumbnailMargin, PGThumbnailSize, PGThumbnailSize);
	return flag ? NSInsetRect(frame, -PGThumbnailMargin, -PGThumbnailMargin) : frame;
}

#pragma mark -

- (void)reloadData
{
	[_selection removeAllObjects]; // TODO: Maintain the selection as much as possible.
	[_items release];
	_items = [[[self dataSource] itemsForThumbnailView:self] copy];
	[self setFrameSize:NSZeroSize];
	[self setNeedsDisplay:YES];
}

#pragma mark PGClipViewDocumentView Protocol

- (BOOL)acceptsClicksInClipView:(PGClipView *)sender
{
	return YES;
}

#pragma mark NSView

- (id)initWithFrame:(NSRect)aRect
{
	if((self = [super initWithFrame:aRect])) {
		_selection = (NSMutableSet *)CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
	}
	return self;
}

#pragma mark -

- (BOOL)isFlipped
{
	return YES;
}
- (void)drawRect:(NSRect)aRect
{
	unsigned i = [self indexOfItemAtPoint:aRect.origin];
	unsigned const max = MIN([_items count], [self indexOfItemAtPoint:NSMakePoint(NSMaxX(aRect), NSMaxY(aRect))] + 1);
	for(; i < max; i++) {
		id const item = [_items objectAtIndex:i];
		if([_selection containsObject:item]) {
			[[NSColor alternateSelectedControlColor] set];
			NSBezierPath *const path = [NSBezierPath AE_bezierPathWithRoundRect:NSInsetRect([self frameOfItemAtIndex:i withMargin:NO], -2, -2) cornerRadius:4.0];
			[path setLineWidth:2.0];
			[path stroke];
		}
		NSImage *const thumb = [[self dataSource] thumbnailView:self thumbnailForItem:item];
		[thumb setFlipped:[self isFlipped]];
		[thumb drawInRect:[self frameOfItemAtIndex:i withMargin:NO] fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:([[self dataSource] thumbnailView:self canSelectItem:item] ? 1.0 : 0.5)];
	}
}

#pragma mark -

- (void)setFrameSize:(NSSize)oldSize
{
	NSView *const superview = [self superview];
	if(!superview) return;
	unsigned const maxCols = (NSWidth([superview bounds]) - PGThumbnailMargin) / PGThumbnailSizeTotal;
	_numberOfColumns = MAX(MIN(ceilf(sqrt([_items count])), maxCols), 1);
	[super setFrameSize:NSMakeSize(_numberOfColumns * PGThumbnailSizeTotal + PGThumbnailMargin, ceilf((float)[_items count] / _numberOfColumns) * PGThumbnailSizeTotal + PGThumbnailMargin)];
}

#pragma mark NSResponder

- (void)mouseDown:(NSEvent *)anEvent
{
	if([[self PG_enclosingClipView] handleMouseDown:anEvent]) return;
	NSPoint const p = [self convertPoint:[anEvent locationInWindow] fromView:nil];
	unsigned const numberOfColumns = [self numberOfColumns];
	unsigned const i = floorf(p.y / PGThumbnailSizeTotal) * numberOfColumns + floorf(p.x / PGThumbnailSizeTotal);
	if(i >= [_items count]) return;
	id const item = [_items objectAtIndex:i];
	BOOL const modifyExistingSelection = !!([anEvent modifierFlags] & (NSShiftKeyMask | NSCommandKeyMask));
	if([_selection containsObject:item]) {
		if(!modifyExistingSelection) return;
		[_selection removeObject:item];
	} else {
		if(!modifyExistingSelection) {
			[_selection removeAllObjects];
			[self setNeedsDisplay:YES];
		}
		[_selection addObject:item];
	}
	[self setNeedsDisplayInRect:[self frameOfItemAtIndex:i withMargin:YES]];
	[[self delegate] thumbnailViewSelectionDidChange:self];
}

#pragma mark NSObject

- (void)dealloc
{
	[_representedObject release];
	[_selection release];
	[super dealloc];
}

@end

@implementation NSObject (PGThumbnailViewDataSource)

- (NSArray *)itemsForThumbnailView:(PGThumbnailView *)sender
{
	return nil;
}
- (NSImage *)thumbnailView:(PGThumbnailView *)sender
             thumbnailForItem:(id)item
{
	return nil;
}
- (BOOL)thumbnailView:(PGThumbnailView *)sender
        canSelectItem:(id)item;
{
	return NO;
}

@end

@implementation NSObject (PGThumbnailViewDelegate)

- (void)thumbnailViewSelectionDidChange:(PGThumbnailView *)sender {}

@end