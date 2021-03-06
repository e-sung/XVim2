//
//  SourceCodeEditorViewProxy+XVim.m
//  XVim2
//
//  Created by Ant on 02/10/2017.
//  Copyright © 2017 Shuichiro Suzuki. All rights reserved.
//

#import "IDEEditor.h"
#import "IDEEditorDocument.h"
#import "NSString+VimHelper.h"
#import "NSTextStorage+VimOperation.h"
#import "SourceCodeEditorViewProxy+XVim.h"
#import "SourceCodeEditorViewProxy.h"
#import "XVim.h"
#import "XVimMotion.h"
#import "XVimOptions.h"
#import <SourceEditor/_TtC12SourceEditor23SourceEditorUndoManager.h>


@interface SourceCodeEditorViewProxy ()
@property (weak) SourceCodeEditorView* sourceCodeEditorView;
@property (readwrite) NSUInteger selectionBegin;
@property (readwrite) XVIM_VISUAL_MODE selectionMode;
@property (readwrite) NSUInteger insertionPoint;
@property (readwrite) NSUInteger preservedColumn;
@property (readwrite) BOOL selectionToEOL;
@property (strong) NSString* lastYankedText;
@property TEXT_TYPE lastYankedType;
@property BOOL xvim_lockSyncStateFromView;
- (void)_xvim_yankSelection:(XVimSelection)sel;
- (void)_xvim_killSelection:(XVimSelection)sel;
@end


@implementation SourceCodeEditorViewProxy (XVim)

- (void)xvim_move:(XVimMotion*)motion
{
    XVimRange r = [self xvim_getMotionRange:self.insertionPoint Motion:motion];
    if (r.end == NSNotFound) {
        return;
    }

    if (self.selectionMode != XVIM_VISUAL_NONE && [motion isTextObject]) {
        if (self.selectionMode == XVIM_VISUAL_LINE) {
            // Motion with text object in VISUAL LINE changes visual mode to VISUAL CHARACTER
            [self setSelectionMode:XVIM_VISUAL_CHARACTER];
        }

        if (self.insertionPoint < self.selectionBegin) {
            // When insertionPoint < selectionBegin it only changes insertion point to beginning of the text object
            [self xvim_moveCursor:r.begin preserveColumn:NO];
        }
        else {
            // Text object expands one text object ( the text object under insertion point + 1 )
            if (![self.textStorage isEOF:self.insertionPoint + 1]) {
                if (motion.motion != TEXTOBJECT_UNDERSCORE) {
                    r = [self xvim_getMotionRange:self.insertionPoint + 1 Motion:motion];
                }
            }
            if (self.selectionBegin > r.begin) {
                self.selectionBegin = r.begin;
            }
            [self xvim_moveCursor:r.end preserveColumn:NO];
        }
    }
    else {
        switch (motion.motion) {
        case MOTION_LINE_BACKWARD:
        case MOTION_LINE_FORWARD:
        case MOTION_LASTLINE:
        case MOTION_LINENUMBER:
            // TODO: Preserve column option can be included in motion object
            if (self.selectionMode == XVIM_VISUAL_BLOCK && self.selectionToEOL) {
                r.end = [self.textStorage xvim_endOfLine:r.end];
            }
            else if (XVIM.options.startofline) {
                // only jump to nonblank line for last line or line number
                if (motion.motion == MOTION_LASTLINE || motion.motion == MOTION_LINENUMBER) {
                    r.end = [self.textStorage xvim_firstNonblankInLineAtIndex:r.end allowEOL:YES];
                }
            }
            [self xvim_moveCursor:r.end preserveColumn:YES];
            break;
        case MOTION_END_OF_LINE:
            self.selectionToEOL = YES;
            [self xvim_moveCursor:r.end preserveColumn:NO];
            break;
        case MOTION_END_OF_WORD_BACKWARD:
            self.selectionToEOL = NO;
            [self xvim_moveCursor:r.begin preserveColumn:NO];
            break;

        default:
            self.selectionToEOL = NO;
            [self xvim_moveCursor:r.end preserveColumn:NO];
            break;
        }
    }
    //[self setNeedsDisplay:YES];
    [self xvim_syncState];
}

- (void)xvim_moveToPosition:(XVimPosition)pos
{
    [self xvim_moveCursor:[self.textStorage xvim_indexOfLineNumber:pos.line column:pos.column] preserveColumn:NO];
    [self xvim_syncState];
}

- (void)xvim_moveCursor:(NSUInteger)pos preserveColumn:(BOOL)preserve
{
    // This method only update the internal state(like self.insertionPoint)

    if (pos > self.string.length) {
        ERROR_LOG(@"[%p]Position specified exceeds the length of the text", self);
        pos = self.string.length;
    }

    if (self.cursorMode == CURSOR_MODE_COMMAND && !(self.selectionMode == XVIM_VISUAL_BLOCK)) {
        self.insertionPoint = [self.textStorage convertToValidCursorPositionForNormalMode:pos];
    }
    else {
        self.insertionPoint = pos;
    }

    if (!preserve) {
        self.preservedColumn = [self.textStorage xvim_columnOfIndex:self.insertionPoint];
    }

    DEBUG_LOG(@"[%p]New Insertion Point:%d   Preserved Column:%d", self, self.insertionPoint, self.preservedColumn);
}

- (void)_adjustCursorPosition
{
#ifdef TODO
    TRACE_LOG(@"[%p]ENTER", self);
    if (![self.textStorage isValidCursorPosition:self.insertionPoint]) {
        NSRange placeholder = [(DVTSourceTextView*)self rangeOfPlaceholderFromCharacterIndex:self.insertionPoint
                                                                                     forward:NO
                                                                                        wrap:NO
                                                                                       limit:0];
        if (placeholder.location != NSNotFound && self.insertionPoint == (placeholder.location + placeholder.length)) {
            // The condition here means that just before current insertion point is a placeholder.
            // So we select the the place holder and its already selected by "selectedPreviousPlaceholder" above
            [self xvim_moveCursor:placeholder.location preserveColumn:YES];
        }
        else {
            [self xvim_moveCursor:self.insertionPoint - 1 preserveColumn:YES];
        }
    }
#endif
}


- (void)xvim_syncStateWithScroll:(BOOL)scroll
{
    DEBUG_LOG(@"[%p]IP:%d", self, self.insertionPoint);
    self.xvim_lockSyncStateFromView = YES;
    // Reset current selection
    if (self.cursorMode == CURSOR_MODE_COMMAND) {
        [self _adjustCursorPosition];
    }
    [self dumpState];

    //[(DVTFoldingTextStorage*)self.textStorage increaseUsingFoldedRanges];
    [self setSelectedRanges:[self xvim_selectedRanges] affinity:NSSelectionAffinityDownstream stillSelecting:NO];
    //[(DVTFoldingTextStorage*)self.textStorage decreaseUsingFoldedRanges];

    if (scroll) {
        [self xvim_scrollTo:self.insertionPoint];
    }
    self.xvim_lockSyncStateFromView = NO;
}


/**
 * Applies internal state to underlying view (self).
 * This update self's property and applies the visual effect on it.
 * All the state need to express Vim is held by this class and
 * we use self to express it visually.
 **/
- (void)xvim_syncState { [self xvim_syncStateWithScroll:YES]; }

- (void)xvim_syncStateFromView
{
    TRACE_LOG(@"[%p]ENTER", self);
    // TODO: handle block selection (if selectedRanges have multiple ranges )
    if (self.xvim_lockSyncStateFromView) {
        return;
    }
    NSRange r = [self selectedRange];
    DEBUG_LOG(@"Selected Range(TotalLen:%d): Loc:%d Len:%d", self.string.length, r.location, r.length);
    self.selectionMode = XVIM_VISUAL_NONE;
    [self xvim_moveCursor:r.location preserveColumn:NO];
    self.selectionBegin = self.insertionPoint;
}


- (void)dumpState
{
    // LOG_STATE();
}

// SELECTION
#pragma mark - SELECTION

// xvim_setSelectedRange is an internal method
// This is used when you want to call [self setSelectedRrange];
// The difference is that this checks the bounds(range can not be include EOF) and protect from Assersion
// Cursor can be on EOF but EOF can not be selected.
// It means that
//   - setSelectedRange:NSMakeRange( indexOfEOF, 0 )   is allowed
//   - setSelectedRange:NSMakeRange( indexOfEOF, 1 )   is not allowed
- (void)xvim_setSelectedRange:(NSRange)range
{
    if ([self.textStorage isEOF:range.location]) {
        [self setSelectedRange:NSMakeRange(range.location, 0)];
        return;
    }
    if (0 == range.length) {
        // No need to check bounds
    }
    else {
        NSUInteger lastIndex = range.location + range.length - 1;
        if ([self.textStorage isEOF:lastIndex]) {
            range.length--;
        }
        else {
            // No need to change the selection area
        }
    }
    [self setSelectedRange:range];
    // LOG_STATE();
}

- (NSArray*)xvim_selectedRanges
{

    if (self.selectionMode != XVIM_VISUAL_BLOCK) {
        return [NSArray arrayWithObject:[NSValue valueWithRange:[self _xvim_selectedRange]]];
    }

    NSMutableArray* rangeArray = [[NSMutableArray alloc] init];
    NSTextStorage* ts = self.textStorage;
    XVimSelection sel = [self _xvim_selectedBlock];

    for (NSUInteger line = sel.top; line <= sel.bottom; line++) {
        NSUInteger begin = [ts xvim_indexOfLineNumber:line column:sel.left];
        NSUInteger end = [ts xvim_indexOfLineNumber:line column:sel.right];

        if ([ts isEOF:begin]) {
            continue;
        }
        if ([ts isEOF:end]) {
            end--;
        }
        else if (sel.right != XVimSelectionEOL && [ts isEOL:end]) {
            end--;
        }
        [rangeArray addObject:[NSValue valueWithRange:NSMakeRange(begin, end - begin + 1)]];
    }
    return rangeArray;
}


- (XVimRange)_xvim_selectedLines
{
    if (self.selectionMode == XVIM_VISUAL_NONE) { // its not in selecting mode
        return (XVimRange){ NSNotFound, NSNotFound };
    }
    else {
        NSUInteger l1 = [self.textStorage xvim_lineNumberAtIndex:self.insertionPoint];
        NSUInteger l2 = [self.textStorage xvim_lineNumberAtIndex:self.selectionBegin];

        return (XVimRange){ MIN(l1, l2), MAX(l1, l2) };
    }
}

- (NSRange)_xvim_selectedRange
{
    if (self.selectionMode == XVIM_VISUAL_NONE) {
        return NSMakeRange(self.insertionPoint, 0);
    }

    if (self.selectionMode == XVIM_VISUAL_CHARACTER) {
        XVimRange xvr = XVimMakeRange(self.selectionBegin, self.insertionPoint);

        if (xvr.begin > xvr.end) {
            xvr = XVimRangeSwap(xvr);
        }
        if ([self.textStorage isEOF:xvr.end]) {
            xvr.end--;
        }
        return XVimMakeNSRange(xvr);
    }

    if (self.selectionMode == XVIM_VISUAL_LINE) {
        XVimRange lines = [self _xvim_selectedLines];
        NSUInteger begin = [self.textStorage xvim_indexOfLineNumber:lines.begin];
        NSUInteger end = [self.textStorage xvim_indexOfLineNumber:lines.end];

        end = [self.textStorage xvim_endOfLine:end];
        if ([self.textStorage isEOF:end]) {
            end--;
        }
        return NSMakeRange(begin, end - begin + 1);
    }

    return NSMakeRange(NSNotFound, 0);
}

- (XVimSelection)_xvim_selectedBlock
{
    XVimSelection result = {};

    if (self.selectionMode == XVIM_VISUAL_NONE) {
        result.top = result.bottom = result.left = result.right = NSNotFound;
        return result;
    }

    NSTextStorage* ts = self.textStorage;
    NSUInteger l1, c11, c12;
    NSUInteger l2, c21, c22;
    NSUInteger tabWidth = ts.xvim_tabWidth;
    NSUInteger pos;

    pos = self.selectionBegin;
    l1 = [ts xvim_lineNumberAtIndex:pos];
    c11 = [ts xvim_columnOfIndex:pos];
    if (!tabWidth || [ts isEOF:pos] || [self.string characterAtIndex:pos] != '\t') {
        c12 = c11;
    }
    else {
        c12 = c11 + tabWidth - (c11 % tabWidth) - 1;
    }

    pos = self.insertionPoint;
    l2 = [ts xvim_lineNumberAtIndex:pos];
    c21 = [ts xvim_columnOfIndex:pos];
    if (!tabWidth || [ts isEOF:pos] || [self.string characterAtIndex:pos] != '\t') {
        c22 = c21;
    }
    else {
        c22 = c21 + tabWidth - (c21 % tabWidth) - 1;
    }

    if (l1 <= l2) {
        result.corner |= _XVIM_VISUAL_BOTTOM;
    }
    if (c11 <= c22) {
        result.corner |= _XVIM_VISUAL_RIGHT;
    }
    result.top = MIN(l1, l2);
    result.bottom = MAX(l1, l2);
    result.left = MIN(c11, c21);
    result.right = MAX(c12, c22);
    if (self.selectionToEOL) {
        result.right = XVimSelectionEOL;
    }
    return result;
}


// Text Range Queries
#pragma mark - TEXT RANGE QUERIES

- (XVimRange)xvim_getMotionRange:(NSUInteger)current Motion:(XVimMotion*)motion
{
    NSRange range = NSMakeRange(NSNotFound, 0);
    NSUInteger begin = current;
    NSUInteger end = NSNotFound;
    NSUInteger tmpPos = NSNotFound;
    NSUInteger start = NSNotFound;
    NSUInteger starts_end = NSNotFound;

    switch (motion.motion) {
    case MOTION_NONE:
        // Do nothing
        break;
    case MOTION_FORWARD:
        motion.option |= MOPT_PLACEHOLDER;
        end = [self.textStorage next:begin count:motion.count option:motion.option info:motion.info];
        break;
    case MOTION_BACKWARD:
        motion.option |= MOPT_PLACEHOLDER;
        end = [self.textStorage prev:begin count:motion.count option:motion.option];
        break;
    case MOTION_WORD_FORWARD:
        motion.option |= MOPT_PLACEHOLDER;
        end = [self.textStorage wordsForward:begin count:motion.count option:motion.option info:motion.info];
        break;
    case MOTION_WORD_BACKWARD:
        motion.option |= MOPT_PLACEHOLDER;
        end = [self.textStorage wordsBackward:begin count:motion.count option:motion.option];
        break;
    case MOTION_END_OF_WORD_FORWARD:
        motion.option |= MOPT_PLACEHOLDER;
        end = [self.textStorage endOfWordsForward:begin count:motion.count option:motion.option];
        break;
    case MOTION_END_OF_WORD_BACKWARD:
        motion.option |= MOPT_PLACEHOLDER;
        end = begin;
        begin = [self.textStorage endOfWordsBackward:begin count:motion.count option:motion.option];
        break;
    case MOTION_LINE_FORWARD:
        if (motion.option & DISPLAY_LINE) {
            end = [self xvim_displayNextLine:begin column:self.preservedColumn count:motion.count option:motion.option];
        }
        else {
            end = [self.textStorage nextLine:begin column:self.preservedColumn count:motion.count option:motion.option];
        }
        break;
    case MOTION_LINE_BACKWARD:
        if (motion.option & DISPLAY_LINE) {
            end = [self xvim_displayPrevLine:begin column:self.preservedColumn count:motion.count option:motion.option];
        }
        else {
            end = [self.textStorage prevLine:begin column:self.preservedColumn count:motion.count option:motion.option];
        }
        break;
    case MOTION_BEGINNING_OF_LINE:
        end = [self.textStorage xvim_startOfLine:begin];
        if (end == NSNotFound) {
            end = current;
        }
        break;
    case MOTION_END_OF_LINE:
        tmpPos = [self.textStorage nextLine:begin column:0 count:motion.count - 1 option:MOTION_OPTION_NONE];
        end = [self.textStorage xvim_endOfLine:tmpPos];
        if (end == NSNotFound) {
            end = tmpPos;
        }
        break;
    case MOTION_SENTENCE_FORWARD:
        end = [self.textStorage sentencesForward:begin count:motion.count option:motion.option];
        break;
    case MOTION_SENTENCE_BACKWARD:
        end = [self.textStorage sentencesBackward:begin count:motion.count option:motion.option];
        break;
    case MOTION_PARAGRAPH_FORWARD:
        end = [self.textStorage paragraphsForward:begin count:motion.count option:motion.option];
        break;
    case MOTION_PARAGRAPH_BACKWARD:
        end = [self.textStorage paragraphsBackward:begin count:motion.count option:motion.option];
        break;
    case MOTION_NEXT_CHARACTER:
        end = [self.textStorage nextCharacterInLine:begin
                                              count:motion.count
                                          character:motion.character
                                             option:MOTION_OPTION_NONE];
        break;
    case MOTION_PREV_CHARACTER:
        end = [self.textStorage prevCharacterInLine:begin
                                              count:motion.count
                                          character:motion.character
                                             option:MOTION_OPTION_NONE];
        break;
    case MOTION_TILL_NEXT_CHARACTER:
        end = [self.textStorage nextCharacterInLine:begin
                                              count:motion.count
                                          character:motion.character
                                             option:motion.option];
        if (end != NSNotFound) {
            end--;
        }
        break;
    case MOTION_TILL_PREV_CHARACTER:
        end = [self.textStorage prevCharacterInLine:begin
                                              count:motion.count
                                          character:motion.character
                                             option:motion.option];
        if (end != NSNotFound) {
            end++;
        }
        break;
    case MOTION_NEXT_FIRST_NONBLANK:
        end = [self.textStorage nextLine:begin column:0 count:motion.count option:motion.option];
        tmpPos = [self.textStorage xvim_nextNonblankInLineAtIndex:end allowEOL:NO];
        if (NSNotFound != tmpPos) {
            end = tmpPos;
        }
        break;
    case MOTION_PREV_FIRST_NONBLANK:
        end = [self.textStorage prevLine:begin column:0 count:motion.count option:motion.option];
        tmpPos = [self.textStorage xvim_nextNonblankInLineAtIndex:end allowEOL:NO];
        if (NSNotFound != tmpPos) {
            end = tmpPos;
        }
        break;
    case MOTION_FIRST_NONBLANK:
        end = [self.textStorage xvim_firstNonblankInLineAtIndex:begin allowEOL:NO];
        break;
    case MOTION_LINENUMBER:
        end = [self.textStorage xvim_indexOfLineNumber:motion.line column:self.preservedColumn];
        if (NSNotFound == end) {
            end = [self.textStorage xvim_indexOfLineNumber:[self.textStorage xvim_numberOfLines]
                                                    column:self.preservedColumn];
        }
        break;
    case MOTION_PERCENT:
        end = [self.textStorage
                    xvim_indexOfLineNumber:1 + ([self.textStorage xvim_numberOfLines] - 1) * motion.count / 100];
        break;
    case MOTION_NEXT_MATCHED_ITEM:
        end = [self.textStorage positionOfMatchedPair:begin];
        break;
    case MOTION_LASTLINE:
        end = [self.textStorage xvim_indexOfLineNumber:[self.textStorage xvim_numberOfLines]
                                                column:self.preservedColumn];
        break;
    case MOTION_HOME:
        end = [self.textStorage
                    xvim_firstNonblankInLineAtIndex:
                                [self.textStorage xvim_indexOfLineNumber:[self xvim_lineNumberFromTop:motion.count]]
                                           allowEOL:YES];
        break;
    case MOTION_MIDDLE:
        end = [self.textStorage
                    xvim_firstNonblankInLineAtIndex:[self.textStorage
                                                                xvim_indexOfLineNumber:[self xvim_lineNumberAtMiddle]]
                                           allowEOL:YES];
        break;
    case MOTION_BOTTOM:
        end = [self.textStorage
                    xvim_firstNonblankInLineAtIndex:
                                [self.textStorage xvim_indexOfLineNumber:[self xvim_lineNumberFromBottom:motion.count]]
                                           allowEOL:YES];
        break;
    case MOTION_SEARCH_FORWARD:
        end = [self.textStorage searchRegexForward:motion.regex
                                              from:self.insertionPoint
                                             count:motion.count
                                            option:motion.option]
                          .location;
        if (end == NSNotFound && !(motion.option & SEARCH_WRAP)) {
            NSRange range = [self xvim_currentWord:MOTION_OPTION_NONE];
            end = range.location;
        }
        break;
    case MOTION_SEARCH_BACKWARD:
        end = [self.textStorage searchRegexBackward:motion.regex
                                               from:self.insertionPoint
                                              count:motion.count
                                             option:motion.option]
                          .location;
        if (end == NSNotFound && !(motion.option & SEARCH_WRAP)) {
            NSRange range = [self xvim_currentWord:MOTION_OPTION_NONE];
            end = range.location;
        }
        break;
    case TEXTOBJECT_WORD:
        range = [self.textStorage currentWord:begin count:motion.count option:motion.option];
        break;
    case TEXTOBJECT_UNDERSCORE:
        range = [self.textStorage currentCamelCaseWord:begin count:motion.count option:motion.option];
        break;
    case TEXTOBJECT_BRACES:
        range = xv_current_block(self.string, current, motion.count, !(motion.option & TEXTOBJECT_INNER), '{', '}');
        break;
    case TEXTOBJECT_PARAGRAPH:
        // Not supported
        start = self.insertionPoint;
        if (start != 0) {
            start = [self.textStorage paragraphsBackward:self.insertionPoint count:1 option:MOPT_PARA_BOUND_BLANKLINE];
        }
        starts_end = [self.textStorage paragraphsForward:start count:1 option:MOPT_PARA_BOUND_BLANKLINE];
        end = [self.textStorage paragraphsForward:self.insertionPoint
                                            count:motion.count
                                           option:MOPT_PARA_BOUND_BLANKLINE];

        if (starts_end != end) {
            start = starts_end;
        }
        range = NSMakeRange(start, end - start);
        break;
    case TEXTOBJECT_PARENTHESES:
        range = xv_current_block(self.string, current, motion.count, !(motion.option & TEXTOBJECT_INNER), '(', ')');
        break;
    case TEXTOBJECT_SENTENCE:
        // Not supported
        break;
    case TEXTOBJECT_ANGLEBRACKETS:
        range = xv_current_block(self.string, current, motion.count, !(motion.option & TEXTOBJECT_INNER), '<', '>');
        break;
    case TEXTOBJECT_SQUOTE:
        range = xv_current_quote(self.string, current, motion.count, !(motion.option & TEXTOBJECT_INNER), '\'');
        break;
    case TEXTOBJECT_DQUOTE:
        range = xv_current_quote(self.string, current, motion.count, !(motion.option & TEXTOBJECT_INNER), '\"');
        break;
    case TEXTOBJECT_TAG:
        // Not supported
        break;
    case TEXTOBJECT_BACKQUOTE:
        range = xv_current_quote(self.string, current, motion.count, !(motion.option & TEXTOBJECT_INNER), '`');
        break;
    case TEXTOBJECT_SQUAREBRACKETS:
        range = xv_current_block(self.string, current, motion.count, !(motion.option & TEXTOBJECT_INNER), '[', ']');
        break;
    case MOTION_LINE_COLUMN:
        end = [self.textStorage xvim_indexOfLineNumber:motion.line column:motion.column];
        if (NSNotFound == end) {
            end = current;
        }
        break;
    case MOTION_POSITION:
    case MOTION_POSITION_JUMP:
        end = motion.position;
        break;
    }

    if (range.location != NSNotFound) { // This block is for TEXTOBJECT
        begin = range.location;
        if (range.length == 0) {
            end = NSNotFound;
        }
        else {
            end = range.location + range.length - 1;
        }
    }
    XVimRange r = XVimMakeRange(begin, end);
    TRACE_LOG(@"range location:%u  length:%u", r.begin, r.end - r.begin + 1);
    return r;
}

- (void)xvim_insert:(XVimInsertionPoint)mode blockColumn:(NSUInteger*)column blockLines:(XVimRange*)lines
{
    NSTextStorage* ts = self.textStorage;

    if (column)
        *column = NSNotFound;
    if (lines)
        *lines = XVimMakeRange(NSNotFound, NSNotFound);

    if (self.selectionMode == XVIM_VISUAL_BLOCK) {
        XVimSelection sel = [self _xvim_selectedBlock];

        if (lines)
            *lines = XVimMakeRange(sel.top, sel.bottom);
        switch (mode) {
        case XVIM_INSERT_BLOCK_KILL:
            [self _xvim_yankSelection:sel];
            [self _xvim_killSelection:sel];
        /* falltrhough */
        case XVIM_INSERT_DEFAULT:
            self.insertionPoint = [ts xvim_indexOfLineNumber:sel.top column:sel.left];
            if (column)
                *column = sel.left;
            break;
        case XVIM_INSERT_APPEND:
            if (sel.right != XVimSelectionEOL) {
                sel.right++;
            }
            self.insertionPoint = [ts xvim_indexOfLineNumber:sel.top column:sel.right];
            if (column)
                *column = sel.right;
            break;
        default:
            NSAssert(false, @"unreachable");
            break;
        }
    }
    else if (mode != XVIM_INSERT_DEFAULT) {
        NSUInteger pos = self.insertionPoint;
        switch (mode) {
        case XVIM_INSERT_APPEND_EOL:
            self.insertionPoint = [ts xvim_endOfLine:pos];
            break;
        case XVIM_INSERT_APPEND:
            NSAssert(self.cursorMode == CURSOR_MODE_COMMAND, @"self.cursorMode shoud be CURSOR_MODE_COMMAND");
            if (![ts isEOF:pos] && ![ts isNewline:pos]) {
                self.insertionPoint = pos + 1;
            }
            break;
        case XVIM_INSERT_BEFORE_FIRST_NONBLANK:
            self.insertionPoint = [ts xvim_firstNonblankInLineAtIndex:pos allowEOL:YES];
            break;
        default:
            NSAssert(false, @"unreachable");
        }
    }
    self.cursorMode = CURSOR_MODE_INSERT;
    [self xvim_changeSelectionMode:XVIM_VISUAL_NONE];
    [self xvim_syncState];
}

- (NSRange)xvim_currentWord:(MOTION_OPTION)opt
{
    return [self.textStorage currentWord:self.insertionPoint count:1 option:opt | TEXTOBJECT_INNER];
}


// UTILITY
#pragma MARK - UTILITY

- (void)_xvim_insertSpaces:(NSUInteger)count replacementRange:(NSRange)replacementRange
{
    if (count || replacementRange.length) {
        [self insertText:[NSString stringMadeOfSpaces:count] replacementRange:replacementRange];
    }
}

- (unichar)xvim_characterAtIndex:(NSInteger)idx
{
    if (self.string.length == 0)
        return 0;
    clamp(idx, 0, self.string.length - 1);
    return [self.string characterAtIndex:idx];
}

- (NSUInteger)xvim_lineNumberFromBottom:(NSUInteger)count
{
    NSAssert(0 != count, @"count starts from 1");
    NSPoint bottomPoint = NSMakePoint(0.0, self.contentSize.height);
    NSInteger bottomLine =
                [self lineRangeForCharacterRange:NSMakeRange([self characterIndexForInsertionAtPoint:bottomPoint], 0)]
                            .location;
    clamp(bottomLine, 0, self.lineCount - 1);
    if (count > 1) {
        bottomLine -= (count - 1);
        clamp(bottomLine, 0, self.lineCount - 1);
    }
    return bottomLine + 1;
}

- (NSUInteger)xvim_lineNumberAtMiddle
{
    _auto topLine = [self xvim_lineNumberFromTop:1];
    _auto bottomLine = [self xvim_lineNumberFromBottom:1];
    return (topLine + bottomLine) / 2;
}

- (NSUInteger)xvim_lineNumberFromTop:(NSUInteger)count
{
    NSAssert(0 != count, @"count starts from 1");
    NSInteger topLine =
                [self lineRangeForCharacterRange:NSMakeRange([self characterIndexForInsertionAtPoint:NSZeroPoint], 0)]
                            .location;
    clamp(topLine, 0, self.lineCount - 1);
    if (count > 1) {
        topLine += (count - 1);
        clamp(topLine, 0, self.lineCount - 1);
    }
    return topLine + 1;
}

- (void)xvim_blockInsertFixupWithText:(NSString*)text
                                     mode:(XVimInsertionPoint)mode
                                    count:(NSUInteger)count
                                   column:(NSUInteger)column
                                    lines:(XVimRange)lines
{
    NSMutableString* buf = nil;
    NSTextStorage* ts;
    NSUInteger tabWidth;

    if (count == 0 || lines.begin > lines.end || text.length == 0) {
        return;
    }
    if ([text rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound) {
        return;
    }
    if (count > 1) {
        buf = [[NSMutableString alloc] initWithCapacity:text.length * count];
        for (NSUInteger i = 0; i < count; i++) {
            [buf appendString:text];
        }
        text = buf;
    }

    ts = self.textStorage;
    tabWidth = ts.xvim_tabWidth;

    for (NSUInteger line = lines.begin; line <= lines.end; line++) {
        NSUInteger pos = [ts xvim_indexOfLineNumber:line column:column];

        if (column != XVimSelectionEOL && [ts isEOL:pos]) {
            if (mode == XVIM_INSERT_SPACES && column == 0) {
                continue;
            }
            if ([ts xvim_columnOfIndex:pos] < column) {
                if (mode != XVIM_INSERT_APPEND) {
                    continue;
                }
                [self _xvim_insertSpaces:column - [ts xvim_columnOfIndex:pos] replacementRange:NSMakeRange(pos, 0)];
            }
        }
        if (tabWidth && [self.string characterAtIndex:pos] == '\t') {
            NSUInteger col = [ts xvim_columnOfIndex:pos];

            if (col < column) {
                [self _xvim_insertSpaces:tabWidth - (col % tabWidth) replacementRange:NSMakeRange(pos, 1)];
                pos += column - col;
            }
        }
        [self insertText:text replacementRange:NSMakeRange(pos, 0)];
    }
}


- (void)xvim_changeSelectionMode:(XVIM_VISUAL_MODE)mode
{
    if (self.selectionMode == XVIM_VISUAL_NONE && mode != XVIM_VISUAL_NONE) {
        self.selectionBegin = self.insertionPoint;
    }
    else if (self.selectionMode != XVIM_VISUAL_NONE && mode == XVIM_VISUAL_NONE) {
        self.selectionBegin = NSNotFound;
    }
    self.selectionMode = mode;
    [self xvim_syncStateWithScroll:NO];
    return;
}

- (void)xvim_escapeFromInsert
{
    if (self.cursorMode == CURSOR_MODE_INSERT) {
        self.cursorMode = CURSOR_MODE_COMMAND;
        if (![self.textStorage isBOL:self.insertionPoint]) {
            [self xvim_moveCursor:self.insertionPoint - 1 preserveColumn:NO];
        }
        [self xvim_syncState];
    }
}


#pragma mark Status

- (NSUInteger)xvim_numberOfLinesInVisibleRect { return self.sourceCodeEditorView.linesPerPage; }

- (NSUInteger)xvim_displayNextLine:(NSUInteger)index
                            column:(NSUInteger)column
                             count:(NSUInteger)count
                            option:(MOTION_OPTION)opt
{
    for (NSUInteger i = 0; i < count; i++) {
        [self.sourceCodeEditorView moveDown:self];
    }
    // TODO
    return [self.sourceCodeEditorView
                       characterRangeForLineRange:NSMakeRange(self.sourceCodeEditorView
                                                                          .accessibilityInsertionPointLineNumber,
                                                              1)]
                       .location
           + self.sourceCodeEditorView.accessibilityColumnIndexRange.location;
}

- (NSUInteger)xvim_displayPrevLine:(NSUInteger)index
                            column:(NSUInteger)column
                             count:(NSUInteger)count
                            option:(MOTION_OPTION)opt
{
    for (NSUInteger i = 0; i < count; i++) {
        [self.sourceCodeEditorView moveUp:self];
    }
    // TODO
    return [self.sourceCodeEditorView
                       characterRangeForLineRange:NSMakeRange(self.sourceCodeEditorView
                                                                          .accessibilityInsertionPointLineNumber,
                                                              1)]
                       .location
           + self.sourceCodeEditorView.accessibilityColumnIndexRange.location;
}

// UNDO


- (void)xvim_registerPositionForUndo:(NSUInteger)pos
{
    __weak SourceCodeEditorViewProxy* weakSelf = self;
    [self.undoManager registerUndoWithTitle:@"BLAH"
                                  redoTitle:@"REBLAH"
                                  operation:^(void) {
                                      SourceCodeEditorViewProxy* SELF = weakSelf;
                                      if (!SELF)
                                          return;
                                      XVimMotion* m = XVIM_MAKE_MOTION(MOTION_POSITION, DEFAULT_MOTION_TYPE,
                                                                       MOTION_OPTION_NONE, 1);
                                      m.position = pos;
                                      [SELF xvim_move:m];
                                  }];
}

- (void)xvim_registerInsertionPointForUndo { [self xvim_registerPositionForUndo:self.selectedRange.location]; }

- (NSUInteger)numberOfSelectedLines
{
    if (XVIM_VISUAL_NONE == self.selectionMode) {
        return 0;
    }
    XVimRange lines = [self _xvim_selectedLines];
    return lines.end - lines.begin + 1;
}


- (void)xvim_highlightNextSearchCandidate:(NSString*)regex
                                        count:(NSUInteger)count
                                       option:(MOTION_OPTION)opt
                                      forward:(BOOL)forward
{
    NSRange range = NSMakeRange(NSNotFound, 0);
    if (forward) {
        range = [self.textStorage searchRegexForward:regex from:self.insertionPoint count:count option:opt];
    }
    else {
        range = [self.textStorage searchRegexBackward:regex from:self.insertionPoint count:count option:opt];
    }
    if (range.location != NSNotFound) {
        [self scrollRangeToVisible:range];
        [self showFindIndicatorForRange:range];
    }
}

- (void)xvim_highlightNextSearchCandidateForward:(NSString*)regex count:(NSUInteger)count option:(MOTION_OPTION)opt
{
    [self xvim_highlightNextSearchCandidate:regex count:count option:opt forward:YES];
}

- (void)xvim_highlightNextSearchCandidateBackward:(NSString*)regex count:(NSUInteger)count option:(MOTION_OPTION)opt
{
    [self xvim_highlightNextSearchCandidate:regex count:count option:opt forward:NO];
}

- (void)xvim_updateFoundRanges:(NSString*)pattern withOption:(MOTION_OPTION)opt
{
    NSAssert(nil != pattern, @"pattern munst not be nil");
    if (!self.needsUpdateFoundRanges) {
        return;
    }

    NSRegularExpressionOptions r_opts = NSRegularExpressionAnchorsMatchLines;
    if (opt & SEARCH_CASEINSENSITIVE) {
        r_opts |= NSRegularExpressionCaseInsensitive;
    }

    NSError* error = nil;
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern options:r_opts error:&error];
    if (nil != error) {
        [self.foundRanges removeAllObjects];
        return;
    }

    // Find all the maches
    NSString* string = self.string;
    // NSTextStorage* storage = self.textStorage;
    if (string == nil) {
        return;
    }
    NSArray* matches = [regex matchesInString:string options:0 range:NSMakeRange(0, string.length)];
    [self.foundRanges setArray:matches];

    // Clear current highlight.
    [self xvim_clearHighlightText];

#ifdef TODO
    XVimOptions* options = [[XVim instance] options];
    NSColor* highlightColor = options.highlight[@"Search"][@"guibg"];
    // Add highlight
    for (NSTextCheckingResult* result in self.foundRanges) {
        [self.layoutManager addTemporaryAttribute:NSBackgroundColorAttributeName
                                            value:highlightColor
                                forCharacterRange:result.range];
    }
#endif

    [self setNeedsUpdateFoundRanges:NO];
}

- (void)xvim_clearHighlightText
{
    if (!self.needsUpdateFoundRanges) {
        return;
    }
#ifdef TODO
    NSString* string = self.string;
    [self.layoutManager removeTemporaryAttribute:NSBackgroundColorAttributeName
                               forCharacterRange:NSMakeRange(0, string.length)];
#endif
    [self setNeedsUpdateFoundRanges:NO];
}


@end
