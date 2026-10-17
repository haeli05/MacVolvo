/* MacVolvo: Steam and Valve's Source 2 games in place of Battle.net and Overwatch.
 *
 * Games. Each is started through Steam (steam.exe -applaunch <id>) with its own options
 * (space-separated): fullscreen or windowed at the chosen size, no joystick polling (-nojoy).
 *
 * Steam's window. On Wine 11 (the engine is CrossOver 26.3) Steam's browser draws black
 * whenever it runs with its GPU off (https://github.com/gauthierpiarrette/highball/issues/282).
 * With the GPU on, Chrome's separate GPU process cannot present into the browser's window
 * (every Wine process has its own Cocoa windows), and this engine's DXMT cannot find a Mac view
 * for Chrome's child window. So GPU web views are turned on (GPUAccelWebViewsV3) and a
 * stand-in steamwebhelper.exe (scripts/webhelper_wrapper.c, shipped as a resource) runs the
 * real one with --in-process-gpu plus WEBHELPER_EXTRA_ARGS (--use-angle=vulkan: ANGLE draws
 * through MoltenVK in the process that owns the window). Steam's startup check would put
 * the original helper back, so Steam starts with -noverifyfiles once the stand-in is in place.
 *
 * Game Mode. The engine's Wine restarts a program listed in WINE_GAME_MODE from
 * lib/wine/game-mode/<name>.app, a bundle that declares itself a game. The engine ships
 * Overwatch.app; one per game is made from it, renamed and signed ad hoc with the same
 * entitlements. verifyRuntime leaves those generated bundles out of the manifest check. */

typedef struct { NSString *key, *name, *exe, *appID, *folder, *options; } MVGame;
static const MVGame mvGames[]={
    {@"cs2",@"Counter-Strike 2",@"cs2.exe",@"730",@"Counter-Strike Global Offensive/game/bin/win64",@"-dx11"},
    // -dx11: DXMT translates Direct3D 11 only, and Deadlock may otherwise pick Vulkan.
    // -novid: skips Deadlock's intro video (CS2 has none).
    {@"deadlock",@"Deadlock",@"deadlock.exe",@"1422450",@"Deadlock/game/bin/win64",@"-dx11 -novid"},
};
static const NSUInteger mvGameCount=sizeof(mvGames)/sizeof(mvGames[0]);
static const MVGame *mvGame(NSString *key) {
    for(NSUInteger i=0;i<mvGameCount;i++)if([mvGames[i].key isEqual:key])return &mvGames[i];
    return NULL;
}
static NSString *steamFolder(void) {return join(root,@"environment/drive_c/Program Files (x86)/Steam");}
static NSString *gamePath(const MVGame *game) {
    return join(join(join(steamFolder(),@"steamapps/common"),game->folder),game->exe);
}
static NSArray *installedGames(void) {
    NSMutableArray *found=[NSMutableArray array];
    for(NSUInteger i=0;i<mvGameCount;i++)if([fm fileExistsAtPath:gamePath(&mvGames[i])])[found addObject:mvGames[i].key];
    return found;
}

/* Steam exposes LaunchOptions from userdata/<account>/config/localconfig.vdf in
 * Library > Properties. Change only those values, while Steam is closed: a live
 * client keeps its own copy and would overwrite an external edit. No account
 * names, config contents or user arguments are ever emitted as support events. */
static NSArray *sessionProcesses(void);
static void mvInvalidSteamConfig(void) {
    @throw [NSException exceptionWithName:@"SteamConfigError" reason:@"invalid_steam_launch_options" userInfo:nil];
}
static NSDictionary *mvVDFToken(NSString *text, NSUInteger *cursor) {
    while(*cursor<text.length) {
        unichar c=[text characterAtIndex:*cursor];
        if([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c] || c==0xfeff) {(*cursor)++;continue;}
        if(c=='/' && *cursor+1<text.length && [text characterAtIndex:*cursor+1]=='/') {
            while(*cursor<text.length && [text characterAtIndex:*cursor]!='\n')(*cursor)++;
            continue;
        }
        break;
    }
    if(*cursor==text.length)return nil;
    NSUInteger start=*cursor;unichar c=[text characterAtIndex:(*cursor)++];
    if(c=='{' || c=='}')return @{@"kind":c=='{'?@"open":@"close",@"range":[NSValue valueWithRange:NSMakeRange(start,1)]};
    NSMutableString *word=[NSMutableString string];
    if(c=='"') {
        BOOL closed=NO;
        while(*cursor<text.length) {
            c=[text characterAtIndex:(*cursor)++];
            if(c=='"') {closed=YES;break;}
            if(c=='\\') {
                if(*cursor==text.length)mvInvalidSteamConfig();
                unichar next=[text characterAtIndex:(*cursor)++];
                if(next=='n')c='\n';else if(next=='r')c='\r';else if(next=='t')c='\t';
                else if(next=='"' || next=='\\')c=next;
                else {[word appendString:@"\\"];c=next;}
            }
            [word appendFormat:@"%C",c];
        }
        if(!closed)mvInvalidSteamConfig();
    } else {
        [word appendFormat:@"%C",c];
        while(*cursor<text.length) {
            c=[text characterAtIndex:*cursor];
            if(c=='{' || c=='}' || [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c])break;
            [word appendFormat:@"%C",c];(*cursor)++;
        }
    }
    return @{@"kind":@"word",@"word":word,@"range":[NSValue valueWithRange:NSMakeRange(start,*cursor-start)]};
}
static NSDictionary *mvVDFObject(NSString *text, NSUInteger *cursor, NSUInteger depth, NSUInteger *budget) {
    if(depth>32)mvInvalidSteamConfig();
    NSMutableArray *children=[NSMutableArray array];
    while(YES) {
        NSDictionary *key=mvVDFToken(text,cursor);
        if(!key) {if(depth)mvInvalidSteamConfig();return @{@"children":children,@"close":@(text.length)};}
        if([key[@"kind"] isEqual:@"close"]) {
            if(!depth)mvInvalidSteamConfig();return @{@"children":children,@"close":@([key[@"range"] rangeValue].location)};
        }
        if(![key[@"kind"] isEqual:@"word"] || !(*budget)--)mvInvalidSteamConfig();
        NSDictionary *value=mvVDFToken(text,cursor);
        NSMutableDictionary *node=[@{@"key":key[@"word"],@"keyRange":key[@"range"]} mutableCopy];
        if([value[@"kind"] isEqual:@"open"]) [node addEntriesFromDictionary:mvVDFObject(text,cursor,depth+1,budget)];
        else if([value[@"kind"] isEqual:@"word"]) {node[@"value"]=value[@"word"];node[@"valueRange"]=value[@"range"];}
        else mvInvalidSteamConfig();
        [children addObject:node];
    }
}
static NSDictionary *mvVDFParse(NSString *text) {
    NSUInteger cursor=0,budget=100000;return mvVDFObject(text,&cursor,0,&budget);
}
static NSDictionary *mvVDFChild(NSDictionary *parent, NSString *key) {
    if(!parent[@"children"])mvInvalidSteamConfig();
    NSDictionary *found=nil;
    for(NSDictionary *child in parent[@"children"])if([child[@"key"] caseInsensitiveCompare:key]==NSOrderedSame) {
        if(found)mvInvalidSteamConfig();found=child;
    }
    return found;
}
static NSDictionary *mvVDFPath(NSDictionary *tree, NSArray *path) {
    NSDictionary *node=tree;
    for(NSString *key in path) {node=mvVDFChild(node,key);if(!node)return nil;}
    return node;
}
static NSString *mvVDFQuote(NSString *word) {
    NSString *escaped=[word stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped=[escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped=[escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    escaped=[escaped stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    escaped=[escaped stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
    return [NSString stringWithFormat:@"\"%@\"",escaped];
}
static NSString *mvVDFIndent(NSString *text, NSDictionary *node) {
    if(!node[@"keyRange"])return @"";
    NSUInteger location=[node[@"keyRange"] rangeValue].location,start=location;
    while(start && [text characterAtIndex:start-1]!='\n')start--;
    NSUInteger end=start;
    while(end<location && ([text characterAtIndex:end]=='\t' || [text characterAtIndex:end]==' '))end++;
    return [text substringWithRange:NSMakeRange(start,end-start)];
}
static NSString *mvVDFInsert(NSString *text, NSDictionary *parent, NSString *body) {
    NSUInteger close=[parent[@"close"] unsignedIntegerValue],start=close;
    while(start && [text characterAtIndex:start-1]!='\n')start--;
    NSString *prefix=[text substringWithRange:NSMakeRange(start,close-start)];
    BOOL ownLine=![prefix stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length;
    NSString *newline=[text containsString:@"\r\n"]?@"\r\n":@"\n";
    NSString *insert=ownLine?body:[newline stringByAppendingString:body];
    NSMutableString *out=[text mutableCopy];[out insertString:insert atIndex:ownLine?start:close];return out;
}
static NSString *mvVDFEnsureObject(NSString *text, NSArray *path) {
    if(!path.count)return text;
    NSArray *parentPath=[path subarrayWithRange:NSMakeRange(0,path.count-1)];
    text=mvVDFEnsureObject(text,parentPath);
    NSDictionary *parent=mvVDFPath(mvVDFParse(text),parentPath),*node=mvVDFChild(parent,path.lastObject);
    if(node) {if(!node[@"children"])mvInvalidSteamConfig();return text;}
    NSString *indent=[mvVDFIndent(text,parent) stringByAppendingString:parentPath.count?@"\t":@""];
    NSString *newline=[text containsString:@"\r\n"]?@"\r\n":@"\n";
    return mvVDFInsert(text,parent,[NSString stringWithFormat:@"%@%@%@%@{%@%@}%@",indent,mvVDFQuote(path.lastObject),newline,indent,newline,indent,newline]);
}

/* Preserve the raw spelling/quoting of unrelated user arguments. Windows quotes
 * are not shell quotes. Reject an unmatched quote rather than swallowing options
 * appended after it or guessing what the user intended. */
static NSArray *mvSteamArgumentTokens(NSString *text) {
    NSMutableArray *tokens=[NSMutableArray array];NSUInteger cursor=0;
    while(cursor<text.length) {
        while(cursor<text.length && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:cursor]])cursor++;
        if(cursor==text.length)break;
        NSUInteger start=cursor,slashes=0;BOOL quoted=NO;
        while(cursor<text.length) {
            unichar c=[text characterAtIndex:cursor];
            if(!quoted && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c])break;
            if(c=='"' && !(slashes%2))quoted=!quoted;
            slashes=c=='\\'?slashes+1:0;cursor++;
        }
        if(quoted)mvInvalidSteamConfig();
        NSString *raw=[text substringWithRange:NSMakeRange(start,cursor-start)],*word=raw;
        if([raw hasPrefix:@"\""] && [raw hasSuffix:@"\""] && raw.length>=2)word=[raw substringWithRange:NSMakeRange(1,raw.length-2)];
        [tokens addObject:@{@"raw":raw,@"word":word.lowercaseString}];
    }
    return tokens;
}
static NSString *mvMergedSteamArguments(NSString *current, NSString *required, BOOL initialFPSCap) {
    NSArray *tokens=mvSteamArgumentTokens(current);NSMutableArray *kept=[NSMutableArray array];BOOL fps=NO;
    NSSet *flags=[NSSet setWithArray:@[@"-nojoy",@"-joy",@"-dx11",@"-dx12",@"-dx9",@"-vulkan",@"-opengl",@"-fullscreen",@"-windowed",@"-window",@"-sw"]];
    NSSet *sizes=[NSSet setWithArray:@[@"-w",@"-width",@"-h",@"-height"]];
    for(NSUInteger i=0;i<tokens.count;i++) {
        NSString *word=tokens[i][@"word"];
        if([word isEqual:@"+fps_max"] || [word hasPrefix:@"+fps_max="])fps=YES;
        if([flags containsObject:word])continue;
        if([word isEqual:@"-novid"] && [required containsString:@"-novid"])continue;
        if([sizes containsObject:word]) {
            if(i+1<tokens.count && [tokens[i+1][@"word"] rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location==NSNotFound)i++;
            continue;
        }
        [kept addObject:tokens[i][@"raw"]];
    }
    [kept insertObject:required atIndex:0];
    if(initialFPSCap && !fps)[kept addObject:@"+fps_max 120"];
    return [kept componentsJoinedByString:@" "];
}
static NSDictionary *steamLaunchDefaults(NSDictionary *gameOptions) {
    NSMutableDictionary *defaults=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<mvGameCount;i++) {
        const MVGame *game=&mvGames[i];NSDictionary *options=gameOptions[game->key];
        NSInteger width=[options[@"width"] integerValue],height=[options[@"height"] integerValue];
        if(width<640 || width>16384 || height<480 || height>16384)continue;
        defaults[game->key]=[NSString stringWithFormat:@"-nojoy %@ -w %ld -h %ld %@",[options[@"fullscreen"] boolValue]?@"-fullscreen":@"-windowed",(long)width,(long)height,game->options];
    }
    return defaults;
}
static NSString *mvUpdatedSteamVDF(NSString *text, NSDictionary *defaults) {
    if(!defaults.count)return text;
    NSArray *appsPath=@[@"UserLocalConfigStore",@"Software",@"Valve",@"Steam",@"apps"];
    text=mvVDFEnsureObject(text,appsPath);
    for(NSUInteger i=0;i<mvGameCount;i++) {
        const MVGame *game=&mvGames[i];NSString *required=defaults[game->key];if(!required)continue;
        NSArray *appPath=[appsPath arrayByAddingObject:game->appID];text=mvVDFEnsureObject(text,appPath);
        NSDictionary *app=mvVDFPath(mvVDFParse(text),appPath),*option=mvVDFChild(app,@"LaunchOptions");
        if(option && !option[@"value"])mvInvalidSteamConfig();
        NSString *before=option[@"value"]?:@"",*after=mvMergedSteamArguments(before,required,[game->key isEqual:@"cs2"]);
        if([before isEqual:after])continue;
        if(option) {NSMutableString *out=[text mutableCopy];[out replaceCharactersInRange:[option[@"valueRange"] rangeValue] withString:mvVDFQuote(after)];text=out;}
        else {
            NSString *newline=[text containsString:@"\r\n"]?@"\r\n":@"\n";
            text=mvVDFInsert(text,app,[NSString stringWithFormat:@"%@\t\"LaunchOptions\"\t\t%@%@",mvVDFIndent(text,app),mvVDFQuote(after),newline]);
        }
    }
    return text;
}
static NSArray *steamLaunchOptionsPlan(NSDictionary *defaults) {
    NSMutableArray *plan=[NSMutableArray array];NSString *userdata=join(steamFolder(),@"userdata");
    for(NSString *account in [fm contentsOfDirectoryAtPath:userdata error:nil]) {
        if(!matches(account,@"^[0-9]+$"))continue;
        NSString *path=join(join(userdata,account),@"config/localconfig.vdf");struct stat st;
        if(lstat(path.fileSystemRepresentation,&st)) {if(errno!=ENOENT)mvInvalidSteamConfig();continue;}
        if(!S_ISREG(st.st_mode) || st.st_size>(16LL<<20) || ![[path stringByResolvingSymlinksInPath] hasPrefix:[root stringByAppendingString:@"/"]])mvInvalidSteamConfig();
        NSData *data=[NSData dataWithContentsOfFile:path];NSString *before=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if(!before)mvInvalidSteamConfig();NSString *after=mvUpdatedSteamVDF(before,defaults);
        if(![before isEqual:after])[plan addObject:@{@"path":path,@"before":data,@"after":[after dataUsingEncoding:NSUTF8StringEncoding]}];
    }
    return plan;
}
static BOOL steamLaunchOptionsNeedUpdate(NSDictionary *defaults, BOOL *needs) {
    @try {*needs=steamLaunchOptionsPlan(defaults).count>0;return YES;} @catch(NSException *ignored) {(void)ignored;return NO;}
}
static BOOL configureSteamLaunchOptions(NSDictionary *defaults) {
    if(sessionProcesses().count)return NO;
    @try {
        NSArray *plan=steamLaunchOptionsPlan(defaults);
        for(NSDictionary *change in plan) {
            NSString *path=change[@"path"],*backup=[path stringByAppendingString:@".macvolvo-backup"];
            if(![[NSData dataWithContentsOfFile:path] isEqual:change[@"before"]])return NO;
            struct stat st;
            if(!lstat(backup.fileSystemRepresentation,&st)) {
                if(!S_ISREG(st.st_mode) || st.st_nlink!=1 || ![[backup stringByResolvingSymlinksInPath] hasPrefix:[root stringByAppendingString:@"/"]])return NO;
            } else if(errno!=ENOENT || ![change[@"before"] writeToFile:backup options:NSDataWritingAtomic error:nil])return NO;
            if(chmod(backup.fileSystemRepresentation,0600))return NO;
            if(![change[@"after"] writeToFile:path options:NSDataWritingAtomic error:nil] || chmod(path.fileSystemRepresentation,0600))return NO;
        }
        if(plan.count)event(@"steam_launch_options_configured",@{@"games":defaults.allKeys});
        return YES;
    } @catch(NSException *ignored) {(void)ignored;return NO;}
}
/* A renderer selected in Deadlock's Video settings is saved here, outside Steam's
 * launch options. Library launches bypass our -dx11 argument, so a saved Vulkan
 * choice would bypass DXMT. Keep those launches on the same supported renderer;
 * preserve the original file and every other field. Call only with games closed. */
static BOOL configureDeadlockRenderer(void) {
    NSString *path=join(steamFolder(),@"steamapps/common/Deadlock/game/citadel/cfg/boot.vcfg");
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if(!text)return YES;
    NSRegularExpression *rx=[NSRegularExpression regularExpressionWithPattern:@"(\"DefaultRenderSystemOption\"\\s+\")-vulkan(\")" options:0 error:nil];
    NSRange whole=NSMakeRange(0,text.length);
    if([rx numberOfMatchesInString:text options:0 range:whole]!=1)return YES;
    NSString *backup=[path stringByAppendingString:@".macvolvo-backup"];
    if(![fm fileExistsAtPath:backup] && ![fm copyItemAtPath:path toPath:backup error:nil])return NO;
    NSString *fixed=[rx stringByReplacingMatchesInString:text options:0 range:whole withTemplate:@"$1-dx11$2"];
    if(![fixed writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil])return NO;
    event(@"game_renderer_configured",@{@"game":@"deadlock",@"renderer":@"dx11"});
    return YES;
}
static NSString *mvProcessName(NSString *name) {
    // Wine may expose either a Windows path or its absolute Unix executable
    // path through ps comm. Keep membership checks independent of that spelling.
    return [[name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent].lowercaseString;
}
static BOOL isGameProcess(NSString *name) {
    NSString *exe=mvProcessName(name);
    for(NSUInteger i=0;i<mvGameCount;i++)if([exe isEqual:mvGames[i].exe])return YES;
    return NO;
}
/* Every game, for WINEMAC_MOUSELOOK (';') and WINE_GAME_MODE (','). */
static NSString *gameList(NSString *separator) {
    NSMutableArray *names=[NSMutableArray array];
    for(NSUInteger i=0;i<mvGameCount;i++)[names addObject:mvGames[i].exe];
    return [names componentsJoinedByString:separator];
}

static BOOL registryValue(NSString *engine, NSString *key, NSString *name, NSString *type, NSString *data, NSString *log) {
    return !waitTask(task(join(engine,@"bin/wine"),@[@"reg.exe",@"add",key,@"/v",name,@"/t",type,@"/d",data,@"/f"],wineEnv(engine),log),60);
}

/* Whether a file is the stand-in: it names the real helper (UTF-16), which Steam's own
 * helper never does. A hash would not do: any earlier build of the stand-in would read as
 * Steam's helper, be moved into the real one's place and start itself without end. */
static BOOL isStandIn(NSString *path) {
    NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSData *mark=[@"steamwebhelper_real.exe" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    return data && [data rangeOfData:mark options:0 range:NSMakeRange(0,data.length)].location!=NSNotFound;
}
/* A first update installs CEF after launch's initial check. Opening Steam again
 * must repair that idle client instead of merely focusing its black window. */
static BOOL steamWindowFixNeeded(void) {
    NSString *cef=join(steamFolder(),@"bin/cef/cef.win64"),*helper=join(cef,@"steamwebhelper.exe"),*real=join(cef,@"steamwebhelper_real.exe");
    if(![fm fileExistsAtPath:helper])return NO; // Steam is still bootstrapping.
    NSString *standIn=[helperPath(@"../Resources/steamwebhelper.exe") stringByStandardizingPath];
    if(!isStandIn(standIn))fail(@"steam_helper_install_failed");
    return !isStandIn(helper) || ![fm fileExistsAtPath:real] || isStandIn(real) || ![hashFile(helper) isEqual:hashFile(standIn)];
}
/* Puts the stand-in helper in place (again after a Steam update replaced it) and turns GPU
 * web views on. NO when Steam's own helper isn't there to run: before Steam's first update,
 * or when it went missing, in which case the stand-ins are removed and Steam's startup check
 * (without -noverifyfiles) puts its helper back; the next start applies the fix. */
static BOOL steamWindowFix(NSString *engine) {
    NSString *cef=join(steamFolder(),@"bin/cef/cef.win64"),*helper=join(cef,@"steamwebhelper.exe"),*real=join(cef,@"steamwebhelper_real.exe");
    // The app ships it as a resource (Contents/Resources, beside Contents/Helpers).
    NSString *standIn=[helperPath(@"../Resources/steamwebhelper.exe") stringByStandardizingPath];
    if(![fm fileExistsAtPath:helper] || !isStandIn(standIn))return NO;
    if(!isStandIn(helper)) {
        // Steam's own helper, first run or after an update: it becomes the real one.
        [fm removeItemAtPath:real error:nil];
        if(![fm moveItemAtPath:helper toPath:real error:nil])fail(@"steam_helper_install_failed");
    } else if(![fm fileExistsAtPath:real] || isStandIn(real)) {
        [fm removeItemAtPath:helper error:nil];[fm removeItemAtPath:real error:nil];
        event(@"steam_helper_restoring",nil);
        return NO;
    } else if([hashFile(helper) isEqual:hashFile(standIn)]) helper=nil;
    if(helper) {
        [fm removeItemAtPath:helper error:nil];
        if(![fm copyItemAtPath:standIn toPath:helper error:nil])fail(@"steam_helper_install_failed");
    }
    if(!registryValue(engine,@"HKCU\\Software\\Valve\\Steam",@"GPUAccelWebViewsV3",@"REG_DWORD",@"1",@"steam-gpu-web-views.log"))fail(@"steam_helper_install_failed");
    return YES;
}

/* Steam lays itself out at Windows' 96 DPI, which Retina mode shows at half size. Twice
 * that (192) keeps its window Mac-sized with sharp text; the games handle it (DPI aware). */
static void configureScaling(NSString *engine) {
    registryValue(engine,@"HKCU\\Control Panel\\Desktop",@"LogPixels",@"REG_DWORD",@"192",@"scaling.log");
}

static void makeGameApps(NSString *engine) {
    NSString *dir=join(engine,@"lib/wine/game-mode"),*source=join(dir,@"Overwatch.app");
    if(![fm fileExistsAtPath:join(source,@"Contents/MacOS/wine")])return;
    NSString *entitlements=join(join(root,@"tmp"),@"game-mode.entitlements");
    for(NSUInteger i=0;i<mvGameCount;i++) {
        NSString *app=join(dir,[mvGames[i].key stringByAppendingString:@".app"]);
        if([fm isExecutableFileAtPath:join(app,@"Contents/MacOS/wine")])continue;
        [fm removeItemAtPath:app error:nil];
        if(![fm copyItemAtPath:source toPath:app error:nil])continue;
        NSString *plist=join(app,@"Contents/Info.plist");
        NSMutableDictionary *info=[[NSDictionary dictionaryWithContentsOfFile:plist] mutableCopy];
        if(!info) {[fm removeItemAtPath:app error:nil];continue;}
        info[@"CFBundleName"]=mvGames[i].name;
        info[@"CFBundleIdentifier"]=[MV_GAME_ID_PREFIX stringByAppendingString:mvGames[i].key];
        info[@"NSMicrophoneUsageDescription"]=[mvGames[i].name stringByAppendingString:@" uses the microphone for voice chat."];
        [info removeObjectForKey:@"NSLocalNetworkUsageDescription"];
        [info writeToFile:plist atomically:YES];
        if(![fm fileExistsAtPath:entitlements])
            waitTask(task(@"/bin/sh",@[@"-c",@"/usr/bin/codesign -d --entitlements :- \"$1\" > \"$2\"",@"sh",source,entitlements],nil,@"game-mode-sign.log"),30);
        if(waitTask(task(@"/usr/bin/codesign",@[@"--force",@"--sign",@"-",@"--options",@"runtime",@"--entitlements",entitlements,app],nil,@"game-mode-sign.log"),60))
            [fm removeItemAtPath:app error:nil];
    }
}
static BOOL generatedGameApp(NSString *name) {
    for(NSUInteger i=0;i<mvGameCount;i++)
        if([name hasPrefix:[NSString stringWithFormat:@"lib/wine/game-mode/%@.app",mvGames[i].key]])return YES;
    return NO;
}

/* The engine's renderer profile names Overwatch.exe; every game gets the same section. */
static NSString *gamesProfile(NSString *profile, NSDictionary *gameOptions) {
    NSRange start=[profile rangeOfString:@"[Overwatch.exe]"];
    if(start.location==NSNotFound)return profile;
    NSString *body=[profile substringFromIndex:NSMaxRange(start)];
    NSRange next=[body rangeOfString:@"\n["];
    if(next.location!=NSNotFound)body=[body substringToIndex:next.location+1];
    NSMutableString *out=[[profile substringToIndex:start.location] mutableCopy];
    for(NSUInteger i=0;i<mvGameCount;i++) {
        const MVGame *game=&mvGames[i];NSDictionary *options=gameOptions[game->key];
        NSInteger width=[options[@"width"] integerValue],height=[options[@"height"] integerValue];
        NSMutableArray *lines=[[body componentsSeparatedByString:@"\n"] mutableCopy];
        for(NSUInteger j=0;j<lines.count;j++) {
            NSString *key=[[lines[j] componentsSeparatedByString:@"="][0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if([key isEqual:@"dxgi.fullscreenCanvasWidth"] && width>=640 && width<=16384)lines[j]=[NSString stringWithFormat:@"%@ = %ld",key,(long)width];
            else if([key isEqual:@"dxgi.fullscreenCanvasHeight"] && height>=480 && height<=16384)lines[j]=[NSString stringWithFormat:@"%@ = %ld",key,(long)height];
            else if([game->key isEqual:@"cs2"] && [key isEqual:@"d3d11.shaderCompilerThreads"])lines[j]=@"d3d11.shaderCompilerThreads = 4";
        }
        [out appendFormat:@"[%@]%@\n",game->exe,[lines componentsJoinedByString:@"\n"]];
    }
    return out;
}
