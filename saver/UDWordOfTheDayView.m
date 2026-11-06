// Urban Word of the Day — a macOS screen saver (macOS 11 Big Sur and later).
//
// Shows headwords from your Urban Dictionary build, one at a time, fading in and
// out at a random spot on a black screen. The word list (words.json) is generated
// by ud2dict.py from the same filtered data as the dictionary and is bundled in
// Contents/Resources, because screen savers run sandboxed and macOS has no public
// API for enumerating a dictionary's headwords.
//
// Build with the Command Line Tools only (no Xcode): see `make saver`.

#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>

static NSString *const kModuleName      = @"local.personal.UrbanWordOfTheDay";
static NSString *const kIntervalKey     = @"interval";
static NSString *const kShowExampleKey  = @"showExample";
static NSString *const kDailyKey        = @"dailyMode";
static const NSTimeInterval kFade       = 1.5;

static NSFont *UDSerif(CGFloat size, NSFontWeight weight, BOOL italic) {
    NSFont *base = [NSFont systemFontOfSize:size weight:weight];
    NSFontDescriptor *desc = [base.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignSerif];
    if (!desc) desc = [NSFont fontWithName:@"Georgia" size:size].fontDescriptor ?: base.fontDescriptor;
    if (italic) desc = [desc fontDescriptorWithSymbolicTraits:desc.symbolicTraits | NSFontDescriptorTraitItalic];
    return [NSFont fontWithDescriptor:desc size:size] ?: base;
}

@interface UDWordOfTheDayView : ScreenSaverView
@end

@implementation UDWordOfTheDayView {
    NSArray<NSDictionary *> *_words;
    NSMutableArray<NSNumber *> *_bag;      // shuffled indices, so words don't repeat soon
    NSDictionary *_current;
    NSAttributedString *_text;
    NSRect _textRect;
    NSPoint _drift;
    NSDate *_shownAt;
    NSTimeInterval _interval;
    BOOL _showExample, _daily;

    NSWindow *_sheet;
    NSPopUpButton *_intervalPopup;
    NSButton *_exampleCheck, *_dailyCheck;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 30.0;
        [[self defaults] registerDefaults:@{ kIntervalKey: @20, kShowExampleKey: @YES, kDailyKey: @NO }];
        [self loadSettings];
        [self loadWords];
    }
    return self;
}

- (ScreenSaverDefaults *)defaults {
    return [ScreenSaverDefaults defaultsForModuleWithName:kModuleName];
}

- (void)loadSettings {
    ScreenSaverDefaults *d = [self defaults];
    _interval    = MAX(5.0, [d doubleForKey:kIntervalKey]);
    _showExample = [d boolForKey:kShowExampleKey];
    _daily       = [d boolForKey:kDailyKey];
}

- (void)loadWords {
    // mainBundle is the screen-saver host app, not this plug-in.
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *path = [bundle pathForResource:@"words" ofType:@"json"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSMutableArray *valid = [NSMutableArray array];
    if ([json isKindOfClass:[NSArray class]]) {
        for (id item in json) {
            if ([item isKindOfClass:[NSDictionary class]] &&
                [item[@"w"] isKindOfClass:[NSString class]] &&
                [item[@"d"] isKindOfClass:[NSString class]]) {
                [valid addObject:item];
            }
        }
    }
    _words = valid;
}

- (void)startAnimation {
    [super startAnimation];
    [self loadSettings];
    [self showNextWord];
}

#pragma mark - Word selection

- (NSUInteger)dailyIndex {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSInteger year = [cal component:NSCalendarUnitYear fromDate:[NSDate date]];
    NSUInteger ordinal = [cal ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitYear forDate:[NSDate date]];
    uint64_t seed = (uint64_t)year * 1000u + ordinal;
    return (NSUInteger)((seed * 2654435761u) % _words.count);  // stable for the whole day
}

- (NSDictionary *)nextWord {
    if (_words.count == 0) return nil;
    if (_daily) return _words[[self dailyIndex]];
    if (_bag.count == 0) {
        _bag = [NSMutableArray arrayWithCapacity:_words.count];
        for (NSUInteger i = 0; i < _words.count; i++) [_bag addObject:@(i)];
        for (NSUInteger i = _bag.count - 1; i > 0; i--) {
            [_bag exchangeObjectAtIndex:i withObjectAtIndex:arc4random_uniform((uint32_t)i + 1)];
        }
    }
    NSUInteger idx = _bag.lastObject.unsignedIntegerValue;
    [_bag removeLastObject];
    return _words[idx];
}

- (void)showNextWord {
    _current = [self nextWord];
    _shownAt = [NSDate date];
    [self layoutCurrentWord];
    [self setNeedsDisplay:YES];
}

#pragma mark - Layout

- (NSAttributedString *)textForWord:(NSDictionary *)word definition:(NSString *)def
                        example:(BOOL)withExample width:(CGFloat)width {
    CGFloat h = NSHeight(self.bounds);
    CGFloat headSize = MAX(12.0, h * 0.075);
    CGFloat bodySize = MAX(7.0, h * 0.026);

    NSMutableParagraphStyle *head = [[NSMutableParagraphStyle alloc] init];
    head.paragraphSpacing = bodySize * 0.4;
    NSMutableParagraphStyle *body = [[NSMutableParagraphStyle alloc] init];
    body.lineSpacing = bodySize * 0.25;
    body.paragraphSpacing = bodySize * 0.9;

    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[word[@"w"] stringByAppendingString:@"\n"]
        attributes:@{ NSFontAttributeName: UDSerif(headSize, NSFontWeightSemibold, NO),
                      NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:1.0],
                      NSParagraphStyleAttributeName: head }]];

    NSString *meta = @"URBAN DICTIONARY";
    NSNumber *up = word[@"u"];
    if ([up isKindOfClass:[NSNumber class]]) {
        meta = [meta stringByAppendingFormat:@"   ▲ %@",
                [NSNumberFormatter localizedStringFromNumber:up numberStyle:NSNumberFormatterDecimalStyle]];
    }
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[meta stringByAppendingString:@"\n"]
        attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:bodySize * 0.62 weight:NSFontWeightMedium],
                      NSKernAttributeName: @(bodySize * 0.08),
                      NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.45],
                      NSParagraphStyleAttributeName: body }]];

    [s appendAttributedString:[[NSAttributedString alloc] initWithString:def
        attributes:@{ NSFontAttributeName: UDSerif(bodySize, NSFontWeightRegular, NO),
                      NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.88],
                      NSParagraphStyleAttributeName: body }]];

    NSString *example = word[@"e"];
    if (withExample && [example isKindOfClass:[NSString class]] && example.length) {
        [s appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"\n“%@”", example]
            attributes:@{ NSFontAttributeName: UDSerif(bodySize * 0.92, NSFontWeightRegular, YES),
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.55],
                          NSParagraphStyleAttributeName: body }]];
    }
    return s;
}

- (NSSize)sizeOfText:(NSAttributedString *)text width:(CGFloat)width {
    NSRect r = [text boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX)
                                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    return NSMakeSize(ceil(NSWidth(r)), ceil(NSHeight(r)));
}

- (void)layoutCurrentWord {
    _text = nil;
    if (!_current) return;

    NSRect b = self.bounds;
    CGFloat width = floor(NSWidth(b) * (self.isPreview ? 0.75 : 0.5));
    CGFloat maxHeight = NSHeight(b) * 0.72;

    // Shrink until it fits: drop the example first, then shorten the definition.
    NSString *def = _current[@"d"];
    BOOL withExample = _showExample;
    NSAttributedString *text = [self textForWord:_current definition:def example:withExample width:width];
    NSSize size = [self sizeOfText:text width:width];
    while (size.height > maxHeight) {
        if (withExample) {
            withExample = NO;
        } else if (def.length > 60) {
            NSString *cut = [def substringToIndex:(NSUInteger)(def.length * 0.8)];
            NSRange space = [cut rangeOfString:@" " options:NSBackwardsSearch];
            def = [(space.location != NSNotFound ? [cut substringToIndex:space.location] : cut)
                   stringByAppendingString:@"…"];
        } else {
            break;
        }
        text = [self textForWord:_current definition:def example:withExample width:width];
        size = [self sizeOfText:text width:width];
    }

    // Random position with a margin; leave room for the slow drift.
    CGFloat margin = NSWidth(b) * 0.07;
    CGFloat driftMax = NSWidth(b) * 0.02;
    CGFloat freeX = MAX(0, NSWidth(b) - size.width - 2 * margin - driftMax);
    CGFloat freeY = MAX(0, NSHeight(b) - size.height - 2 * margin);
    CGFloat x = margin + (freeX > 0 ? SSRandomFloatBetween(0, freeX) : 0);
    CGFloat y = margin + (freeY > 0 ? SSRandomFloatBetween(0, freeY) : 0);

    _text = text;
    _textRect = NSMakeRect(floor(x), floor(y), size.width, size.height);
    _drift = NSMakePoint(driftMax / _interval, 0);  // px per second
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)rect {
    [[NSColor blackColor] setFill];
    NSRectFill(self.bounds);

    if (!_text) {
        NSString *msg = _words.count ? @"" :
            @"No words found. Rebuild the screen saver with `make saver`.";
        NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:MAX(9, NSHeight(self.bounds) * 0.022)],
                                 NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.6] };
        NSSize sz = [msg sizeWithAttributes:attrs];
        [msg drawAtPoint:NSMakePoint(NSMidX(self.bounds) - sz.width / 2, NSMidY(self.bounds) - sz.height / 2)
          withAttributes:attrs];
        return;
    }

    NSTimeInterval t = -[_shownAt timeIntervalSinceNow];
    CGFloat alpha = (CGFloat)MIN(1.0, MIN(t / kFade, (_interval - t) / kFade));
    if (alpha <= 0) return;

    CGContextRef ctx = [NSGraphicsContext currentContext].CGContext;
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, alpha);
    NSRect r = NSOffsetRect(_textRect, floor(_drift.x * t), 0);
    [_text drawInRect:r];  // top-aligned layout in both flipped and unflipped views
    CGContextRestoreGState(ctx);
}

- (void)animateOneFrame {
    if (_current && -[_shownAt timeIntervalSinceNow] >= _interval) {
        [self showNextWord];  // in daily mode: same word, new position
    }
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutCurrentWord];
}

#pragma mark - Options sheet

- (BOOL)hasConfigureSheet { return YES; }

- (NSWindow *)configureSheet {
    if (!_sheet) [self buildSheet];
    ScreenSaverDefaults *d = [self defaults];
    [_intervalPopup selectItemWithTag:[d integerForKey:kIntervalKey]];
    if (!_intervalPopup.selectedItem) [_intervalPopup selectItemWithTag:20];
    _exampleCheck.state = [d boolForKey:kShowExampleKey] ? NSControlStateValueOn : NSControlStateValueOff;
    _dailyCheck.state = [d boolForKey:kDailyKey] ? NSControlStateValueOn : NSControlStateValueOff;
    return _sheet;
}

- (void)buildSheet {
    _sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 190)
                                         styleMask:NSWindowStyleMaskTitled
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    NSView *v = _sheet.contentView;

    NSTextField *label = [NSTextField labelWithString:@"Show each word for:"];
    label.frame = NSMakeRect(20, 140, 150, 20);
    [v addSubview:label];

    _intervalPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(175, 135, 160, 26) pullsDown:NO];
    for (NSNumber *secs in @[@10, @20, @30, @60, @120]) {
        [_intervalPopup addItemWithTitle:[NSString stringWithFormat:@"%@ seconds", secs]];
        _intervalPopup.lastItem.tag = secs.integerValue;
    }
    [v addSubview:_intervalPopup];

    _exampleCheck = [NSButton checkboxWithTitle:@"Show example sentence" target:nil action:nil];
    _exampleCheck.frame = NSMakeRect(18, 105, 320, 20);
    [v addSubview:_exampleCheck];

    _dailyCheck = [NSButton checkboxWithTitle:@"One word per day (instead of cycling)" target:nil action:nil];
    _dailyCheck.frame = NSMakeRect(18, 78, 320, 20);
    [v addSubview:_dailyCheck];

    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(closeSheetSave:)];
    ok.keyEquivalent = @"\r";
    ok.frame = NSMakeRect(250, 15, 90, 32);
    [v addSubview:ok];

    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(closeSheetCancel:)];
    cancel.keyEquivalent = @"\033";
    cancel.frame = NSMakeRect(155, 15, 90, 32);
    [v addSubview:cancel];
}

- (void)closeSheetSave:(id)sender {
    ScreenSaverDefaults *d = [self defaults];
    [d setInteger:_intervalPopup.selectedTag forKey:kIntervalKey];
    [d setBool:_exampleCheck.state == NSControlStateValueOn forKey:kShowExampleKey];
    [d setBool:_dailyCheck.state == NSControlStateValueOn forKey:kDailyKey];
    [d synchronize];
    [self loadSettings];
    _bag = nil;
    [self showNextWord];
    [self closeSheet];
}

- (void)closeSheetCancel:(id)sender { [self closeSheet]; }

- (void)closeSheet {
    if (_sheet.sheetParent) {
        [_sheet.sheetParent endSheet:_sheet];
    } else {
        [NSApp endSheet:_sheet];
    }
}

@end
