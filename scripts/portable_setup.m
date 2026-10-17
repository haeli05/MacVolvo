/* Native Phase 2 setup worker. Original project contributions: Apache-2.0.
 * Foundation/libarchive/CommonCrypto are supplied by macOS; no player Python.
 * The future app supplies a reviewed archive URL/hash/version, never arbitrary
 * downloaded executable instructions. JSON events are deliberately account-free.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <archive.h>
#include <archive_entry.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <signal.h>
#include <math.h>
#include <unistd.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function" // MetalFX environment: Overwatch only
#include "candidate_contract.generated.h"
#pragma clang diagnostic pop

#ifdef MACVOLVO_GPTK4
#define MV_DATA_FOLDER @"MacVolvo GPTK4"
#define MV_OWNER_MARKER @".macvolvo-gptk4-owner"
#define MV_OTHER_OWNER_MARKER @".macvolvo-owner"
#define MV_OWNER_TEXT "macvolvo-gptk4-v01\n"
#define MV_GAME_ID_PREFIX @"app.macvolvo.gptk4.game."
#else
#define MV_DATA_FOLDER @"MacVolvo"
#define MV_OWNER_MARKER @".macvolvo-owner"
#define MV_OTHER_OWNER_MARKER @".macvolvo-gptk4-owner"
#define MV_OWNER_TEXT "macvolvo-native-v01\n"
#define MV_GAME_ID_PREFIX @"app.macvolvo.game."
#endif

static NSFileManager *fm;
static NSString *root;
static int lockFD = -1;
static BOOL monitorMode;
static BOOL ownedPreparation;
static volatile sig_atomic_t childPID;
static volatile sig_atomic_t cancelRequested;
static void cancelled(int sig) { cancelRequested=sig; if (childPID > 0) kill(childPID, SIGTERM); }
static void fail(NSString *code) { @throw [NSException exceptionWithName:@"SetupError" reason:code userInfo:nil]; }
static NSString *join(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }
static void event(NSString *stage, NSDictionary *details) {
    NSMutableDictionary *value = [@{@"stage":stage} mutableCopy];
    [value addEntriesFromDictionary:details ?: @{}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}
static void mkdirs(NSString *path) {
    if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions:@0700} error:nil]) fail(@"directory_creation_failed");
}
static void writeJSON(id object, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:nil]) fail(@"state_write_failed");
}
static NSDictionary *readJSON(NSString *path) {
    if([[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue]>(8ULL<<20))fail(@"manifest_size_limit");
    NSData *data = [NSData dataWithContentsOfFile:path];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![value isKindOfClass:NSDictionary.class]) fail(@"invalid_manifest");
    return value;
}
static BOOL matches(NSString *s, NSString *pattern) {
    if (!s) return NO;
    NSRange range = [s rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location == 0 && range.length == s.length;
}
static BOOL safePath(NSString *s) {
    if (!s.length || [s hasPrefix:@"/"] || [s containsString:@"\\"] || [s containsString:@"\n"] ||
        [s containsString:@"\r"] || [s containsString:@"\t"]) return NO;
    for (NSString *part in [s componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static NSString *hashFile(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) fail(@"file_read_failed");
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) { close(fd); fail(@"file_not_regular"); }
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    unsigned char buffer[1024*128], digest[CC_SHA256_DIGEST_LENGTH]; ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    close(fd); if (count < 0) fail(@"file_read_failed");
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString string];
    for (unsigned int i=0; i<sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
static uint64_t freeBytes(void) {
    return [[fm attributesOfFileSystemForPath:root error:nil][NSFileSystemFreeSize] unsignedLongLongValue];
}
static void space(uint64_t needed) { if (freeBytes() < needed) fail(@"insufficient_disk_space"); }
static void supportedVolume(NSString *path) {
    // Wine needs POSIX symlinks and Windows games expect case-insensitive
    // names: only APFS or Mac OS Extended, never case-sensitive or read-only.
    struct statfs fs;
    if (statfs(path.fileSystemRepresentation,&fs)) fail(@"install_location_unavailable");
    if (strcmp(fs.f_fstypename,"apfs") && strcmp(fs.f_fstypename,"hfs")) fail(@"unsupported_volume_format");
    if (fs.f_flags & MNT_RDONLY) fail(@"read_only_volume");
    if (pathconf(path.fileSystemRepresentation,_PC_CASE_SENSITIVE) == 1) fail(@"case_sensitive_volume");
}
static void ownRoot(NSString *requested) {
    root = [[requested stringByStandardizingPath] stringByResolvingSymlinksInPath];
    if (![root isAbsolutePath] || [root isEqual:@"/"] || [root isEqual:NSHomeDirectory()]) fail(@"unsafe_install_directory");
    for(NSString *ancestor=root;![ancestor isEqual:@"/"];ancestor=ancestor.stringByDeletingLastPathComponent)
        if([fm fileExistsAtPath:join(ancestor,MV_OTHER_OWNER_MARKER)])fail(@"directory_not_owned_by_app");
    // Only the data folder itself is ever created. A disconnected external
    // drive must not turn into a stray folder on the internal disk.
    NSString *parent = [root stringByDeletingLastPathComponent];
    BOOL parentIsDirectory = NO;
    if (![fm fileExistsAtPath:root] && !([fm fileExistsAtPath:parent isDirectory:&parentIsDirectory] && parentIsDirectory))
        fail(@"install_location_unavailable");
    // An unclean eject can leave an empty /Volumes/<name> folder: require a mount.
    NSArray *parts = root.pathComponents;
    if (parts.count > 3 && [parts[1] isEqual:@"Volumes"] && ![fm fileExistsAtPath:root]) {
        NSString *volume = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,3)]];
        struct statfs mounted;
        if (statfs(volume.fileSystemRepresentation,&mounted) || strcmp(mounted.f_mntonname,volume.fileSystemRepresentation)) fail(@"install_location_unavailable");
    }
    NSString *marker = join(root,MV_OWNER_MARKER);
    if ([fm fileExistsAtPath:root] && ![fm fileExistsAtPath:marker] &&
        [fm contentsOfDirectoryAtPath:root error:nil].count) fail(@"directory_not_owned_by_app");
    // New locations only: an existing installation is never re-judged.
    if (![fm fileExistsAtPath:marker]) supportedVolume([fm fileExistsAtPath:root] ? root : parent);
    mkdirs(root);
    struct stat st;
    if (lstat(root.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid()) fail(@"directory_not_owned_by_user");
    if (chmod(root.fileSystemRepresentation,0700)) fail(@"private_directory_permissions_failed");
    int markerFD = open(marker.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW,0600);
    if (markerFD < 0) fail(@"invalid_ownership_marker");
    char bytes[32] = {0}; ssize_t n=read(markerFD,bytes,sizeof(bytes));
    const size_t markerLength=sizeof(MV_OWNER_TEXT)-1;
    if (n==0) { if(write(markerFD,MV_OWNER_TEXT,markerLength)!=(ssize_t)markerLength) {close(markerFD);fail(@"ownership_write_failed");} }
    else if(n!=(ssize_t)markerLength || memcmp(bytes,MV_OWNER_TEXT,markerLength)) {close(markerFD);fail(@"invalid_ownership_marker");}
    close(markerFD);
    lockFD=open(join(root,@"setup.lock").fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(lockFD<0)fail(@"setup_already_running");
    if(monitorMode) { if(flock(lockFD,LOCK_EX))fail(@"setup_already_running"); }
    else if(flock(lockFD,LOCK_EX|LOCK_NB))fail(@"setup_already_running");
    for (NSString *directory in @[@"runtimes",@"downloads",@"logs",@"home",@"tmp",@"cache"])
        mkdirs(join(root,directory));
}
static NSMutableDictionary *state(void) {
    NSString *p=join(root,@"state.json");
    return [fm fileExistsAtPath:p] ? [readJSON(p) mutableCopy] : [@{@"schema":@1,@"stage":@"not_installed"} mutableCopy];
}
static void saveStage(NSString *stage) {
    NSMutableDictionary *s=state();s[@"stage"]=stage;writeJSON(s,join(root,@"state.json"));event(stage,nil);
}
static NSString *runtime(void) {
    NSString *version=state()[@"active_runtime"];
    if(!matches(version,@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) fail(@"runtime_not_installed");
    NSString *p=join(join(root,@"runtimes"),version);
    if (![fm fileExistsAtPath:join(p,@"runtime.json")]) fail(@"runtime_missing");
    return p;
}
static NSString *gameList(NSString *separator); // portable_steam.h
static NSMutableDictionary *wineEnv(NSString *engine) {
    // Keep Wine's Windows profile and shell-folder symlinks inside this new
    // environment. Never borrow the developer's HOME, account state or caches.
    NSMutableDictionary *env=[candidateEnvironment() mutableCopy];
    [env addEntriesFromDictionary:@{@"PATH":@"/usr/bin:/bin:/usr/sbin:/sbin",@"HOME":join(root,@"home"),@"USER":@"player",
        @"TMPDIR":join(root,@"tmp"),@"WINEPREFIX":join(root,@"environment"),@"WINEARCH":@"win64",
        @"WINESERVER":join(engine,@"bin/wineserver"),@"WINELOADER":join(engine,@"bin/wine"),
        @"WINEDEBUG":@"-all",
        @"CX_APPLEGPTK_LIBD3DSHARED_PATH":join(engine,@"lib/external/libd3dshared.dylib"),
        @"DXMT_SHADER_CACHE_PATH":join(root,@"cache/shaders"),@"DXMT_LOG_LEVEL":@"error",@"DXMT_LOG_PATH":@"none",
        @"DXMT_CONFIG_FILE":[@"Z:" stringByAppendingString:[([fm fileExistsAtPath:join(root,@"dxmt.conf")]?join(root,@"dxmt.conf"):join(engine,@"config/dxmt.conf")) stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]],
        @"DXMT_PIPELINE_CACHE_PATH":join(root,@"cache/pipelines")}];
    // The contract names Overwatch; MacVolvo's games take its place (portable_steam.h).
    [env addEntriesFromDictionary:@{@"WINEMAC_MOUSELOOK":gameList(@";"),@"WINE_GAME_MODE":gameList(@","),
        @"DXMT_PIPELINE_CACHE_NAMESPACE":@"macvolvo-v1",
        // Chrome flags for Steam's browser (portable_steam.h); the worker's own environment
        // can set others, for testing.
        @"WEBHELPER_EXTRA_ARGS":NSProcessInfo.processInfo.environment[@"WEBHELPER_EXTRA_ARGS"] ?: @"--use-angle=vulkan"}];
#ifdef MACVOLVO_GPTK4
    for(NSString *key in env.allKeys)if([key hasPrefix:@"DXMT_"])[env removeObjectForKey:key];
    [env addEntriesFromDictionary:@{@"CX_ACTIVE_GRAPHICS_BACKEND":@"d3dmetal",@"CX_GRAPHICS_BACKEND":@"d3dmetal",
        @"WINEDLLOVERRIDES":@"d3d11,dxgi,d3d10=b;d3d10core,winemetal,d3d12,d3d12core,nvapi64,nvngx=",
        @"D3DMETAL_FRAMEWORK_PATH":join(engine,@"lib/external/D3DMetal.framework/D3DMetal"),@"D3DM_ENABLE_METALFX":@"0",
        @"MACVOLVO_GPTK4_DISPLAY_FIX":@"1"}];
#endif
    return env;
}
static NSTask *task(NSString *executable, NSArray *args, NSDictionary *env, NSString *logname) {
    NSTask *p=[NSTask new];p.executableURL=[NSURL fileURLWithPath:executable];p.arguments=args;
    if(env)p.environment=env;
    p.currentDirectoryURL=[NSURL fileURLWithPath:root];
    NSString *log=join(join(root,@"logs"),logname);
    if(![fm fileExistsAtPath:log]) [fm createFileAtPath:log contents:nil attributes:@{NSFilePosixPermissions:@0600}];
    NSFileHandle *out=[NSFileHandle fileHandleForWritingAtPath:log];[out truncateFileAtOffset:0];
    p.standardOutput=out;p.standardError=out;
    if(![p launchAndReturnError:nil]) fail(@"process_launch_failed");
    return p;
}
// tick, if any, runs while the task does and once after it exits.
static int waitTaskTicking(NSTask *p, double seconds, void (^tick)(void)) {
    childPID=p.processIdentifier;
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(p.running && deadline.timeIntervalSinceNow>0 && !cancelRequested) {[NSThread sleepForTimeInterval:0.05];if(tick)tick();}
    if(p.running) {
        kill(p.processIdentifier,SIGTERM);
        NSDate *grace=[NSDate dateWithTimeIntervalSinceNow:2];
        while(p.running && grace.timeIntervalSinceNow>0) [NSThread sleepForTimeInterval:0.05];
        if(p.running)kill(p.processIdentifier,SIGKILL);
        [p waitUntilExit];childPID=0;if(cancelRequested)fail(@"cancelled");return 124;
    }
    [p waitUntilExit];childPID=0;if(tick)tick();if(cancelRequested)fail(@"cancelled");return p.terminationStatus;
}
static int waitTask(NSTask *p, double seconds) { return waitTaskTicking(p,seconds,nil); }
static BOOL busy(NSString *engine) {
    if(![fm fileExistsAtPath:join(root,@"environment")]) return NO;
    NSTask *p=task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"server-check.log");
    // A newly signed x86_64 server may need first-launch Rosetta translation.
    // A subsecond deadline falsely classified that startup as a running game.
    int result=waitTask(p,5);
    if(result!=0 && result!=124)fail(@"server_check_failed");
    return result==124;
}
static NSString *helperPath(NSString *name) {
    return join([NSProcessInfo.processInfo.arguments[0] stringByDeletingLastPathComponent],name);
}
#include "portable_steam.h"
#include "portable_session.h"
#include "portable_preferences.h"
#include "portable_retina.h"
#include "portable_voice.h"
#include "portable_network.h"
// Overwatch-only (Korean accounts, MetalFX through DLSS): kept for the support commands.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "portable_korea.h"
#include "portable_metalfx.h"
#pragma clang diagnostic pop
#include "portable_diagnostics.h"
// Tests build the worker with a probe that fails, as on a Mac without Rosetta.
#ifndef ROSETTA_PROBE
#define ROSETTA_PROBE @"/usr/bin/arch"
#endif
// Battle.net, Overwatch and Wine are Intel programs. Upgrading to macOS 27 doesn't keep
// Rosetta (issue #15), so launches check too, before anything starts Wine.
static void requireRosetta(void) {
    if(waitTask(task(ROSETTA_PROBE,@[@"-x86_64",@"/usr/bin/true"],nil,@"rosetta-check.log"),10))fail(@"rosetta_required");
}
static void preflight(void) {
    int silicon=0;size_t size=sizeof(silicon);
    sysctlbyname("hw.optional.arm64",&silicon,&size,NULL,0);
    if(!silicon)fail(@"apple_silicon_required");
    // Overwatch needs Rosetta's fixes in macOS 26.5; on older macOS it hangs before its window opens.
    if(![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26,5,0}])fail(@"macos_26_5_required");
    requireRosetta();
    event(@"preflight_ok",@{@"free_bytes":@(freeBytes()),@"runtime_headroom_bytes":@(6ULL<<30)});
}
static NSString *download(NSString *url, NSString *expected) {
    if(!matches(expected,@"^[a-f0-9]{64}$"))fail(@"invalid_download_hash");
    NSURL *u=[NSURL URLWithString:url];
    if(![u.scheme isEqual:@"https"] || !u.host.length || u.user || u.password)fail(@"https_download_required");
    NSString *dest=join(join(root,@"downloads"),expected);
    if([fm fileExistsAtPath:dest]) {
        if(![hashFile(dest) isEqual:expected])fail(@"cached_download_hash_mismatch");return dest;
    }
    space(3ULL<<30);
    NSString *part=[dest stringByAppendingString:@".part"];
    struct stat st;
    if(!lstat(part.fileSystemRepresentation,&st) && !S_ISREG(st.st_mode))fail(@"unsafe_partial_download");
    event(@"downloading",nil);
    NSArray *args=@[@"--fail",@"--location",@"--proto",@"=https",@"--proto-redir",@"=https",
        @"--retry",@"2",@"--connect-timeout",@"20",@"--max-time",@"1800",@"--max-filesize",@"4294967296",
        @"--continue-at",@"-",@"--output",part,url];
    int code=waitTask(task(@"/usr/bin/curl",args,nil,@"download.log"),1810);
    if(code==33 || code==36) {
        [fm removeItemAtPath:part error:nil];
        code=waitTask(task(@"/usr/bin/curl",args,nil,@"download.log"),1810);
    }
    if(code)fail(@"download_interrupted_retry_to_resume");
    if(![hashFile(part) isEqual:expected]) { [fm removeItemAtPath:part error:nil];fail(@"download_hash_mismatch"); }
    if(![fm moveItemAtPath:part toPath:dest error:nil])fail(@"download_commit_failed");
    event(@"download_verified",nil);return dest;
}
static void extract(NSString *archivePath, NSString *destination) {
    struct archive *a=archive_read_new();archive_read_support_filter_gzip(a);archive_read_support_format_tar(a);
    if(archive_read_open_filename(a,archivePath.fileSystemRepresentation,131072)!=ARCHIVE_OK)fail(@"archive_open_failed");
    NSMutableSet *seen=[NSMutableSet set];NSMutableArray *links=[NSMutableArray array];
    struct archive_entry *entry;uint64_t total=0;int result;
    @try {
        while((result=archive_read_next_header(a,&entry))==ARCHIVE_OK) {
            if(cancelRequested)fail(@"cancelled");
            NSString *name=[NSString stringWithUTF8String:archive_entry_pathname(entry)];
            if([name hasSuffix:@"/"])name=[name substringToIndex:name.length-1];
            if(!safePath(name) || [seen containsObject:name.lowercaseString] || seen.count>20000)fail(@"unsafe_archive_path");
            [seen addObject:name.lowercaseString];
            if(archive_entry_hardlink(entry))fail(@"archive_hardlink_rejected");
            mode_t type=archive_entry_filetype(entry);NSString *dest=join(destination,name);
            if(type==AE_IFLNK) {
                const char *raw=archive_entry_symlink(entry);NSString *link=raw?[NSString stringWithUTF8String:raw]:nil;
                if(!link.length || [link hasPrefix:@"/"] || [link containsString:@"\\"])fail(@"unsafe_archive_symlink");
                // Foundation retains '..' in relative standardized paths.
                // Normalize lexically before links exist, without traversing any.
                NSMutableArray *parts=[[name.stringByDeletingLastPathComponent componentsSeparatedByString:@"/"] mutableCopy];
                [parts removeObject:@""];
                for(NSString *part in [link componentsSeparatedByString:@"/"]) {
                    if(!part.length || [part isEqual:@"."])continue;
                    if([part isEqual:@".."]) {
                        if(!parts.count)fail(@"archive_symlink_escapes_runtime");
                        [parts removeLastObject];
                    } else [parts addObject:part];
                }
                NSString *resolved=[parts componentsJoinedByString:@"/"];
                if(!safePath(resolved))fail(@"archive_symlink_escapes_runtime");
                [links addObject:@[dest,link]];continue;
            }
            if(type!=AE_IFREG && type!=AE_IFDIR)fail(@"archive_special_file_rejected");
            mkdirs(dest.stringByDeletingLastPathComponent);
            if(type==AE_IFDIR) {mkdirs(dest);continue;}
            la_int64_t length=archive_entry_size(entry);
            if(length<0 || length>(2LL<<30) || total+(uint64_t)length>(8ULL<<30))fail(@"archive_size_limit");
            total+=(uint64_t)length;
            int fd=open(dest.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,
                        archive_entry_perm(entry)&0111 ? 0755:0644);
            if(fd<0)fail(@"archive_file_creation_failed");
            char buffer[131072];la_ssize_t n;uint64_t wrote=0;
            while((n=archive_read_data(a,buffer,sizeof(buffer)))>0) {
                ssize_t offset=0;
                while(offset<n) {ssize_t count=write(fd,buffer+offset,(size_t)(n-offset));if(count<=0){close(fd);fail(@"archive_write_failed");}offset+=count;}
                wrote+=(uint64_t)n;
            }
            close(fd);if(n<0 || wrote!=(uint64_t)length)fail(@"archive_truncated");
        }
        if(result!=ARCHIVE_EOF)fail(@"archive_corrupt");
        // No symlink can be traversed during extraction: create all of them last.
        for(NSArray *link in links) {
            NSString *parent=[link[0] stringByDeletingLastPathComponent];
            NSString *relative=[parent substringFromIndex:destination.length];
            NSString *cursor=destination;
            for(NSString *part in [relative componentsSeparatedByString:@"/"]) {
                if(!part.length)continue;cursor=join(cursor,part);struct stat st;
                if(!lstat(cursor.fileSystemRepresentation,&st) && !S_ISDIR(st.st_mode))fail(@"archive_symlink_parent_rejected");
                mkdirs(cursor);
            }
            if(symlink([link[1] fileSystemRepresentation],[link[0] fileSystemRepresentation]))fail(@"archive_symlink_failed");
        }
        NSString *canonicalDestination=[destination stringByResolvingSymlinksInPath];
        for(NSArray *link in links) {
            NSString *resolved=[link[0] stringByResolvingSymlinksInPath];
            if(![resolved hasPrefix:[canonicalDestination stringByAppendingString:@"/"]])fail(@"archive_symlink_escapes_runtime");
        }
    } @finally {archive_read_free(a);}
}
static void verifyRuntime(NSString *engine, NSString *version) {
    NSDictionary *manifest=readJSON(join(engine,@"runtime.json"));
    if(![manifest[@"version"] isEqual:version] || ![manifest[@"files"] isKindOfClass:NSDictionary.class])fail(@"runtime_identity_mismatch");
    NSDictionary *files=manifest[@"files"];
#ifdef MACVOLVO_GPTK4
    if(![manifest[@"graphics_backend"] isEqual:@"d3dmetal"] || ![manifest[@"gptk_version"] hasPrefix:@"4."])fail(@"runtime_identity_mismatch");
#else
    if(manifest[@"graphics_backend"] && ![manifest[@"graphics_backend"] isEqual:@"dxmt"])fail(@"runtime_identity_mismatch");
#endif
    for(NSString *name in files) {
        if(cancelRequested)fail(@"cancelled");
        if(!safePath(name))fail(@"unsafe_manifest_path");
        NSDictionary *spec=files[name];NSString *p=join(engine,name);struct stat st;
        if(lstat(p.fileSystemRepresentation,&st))fail(@"runtime_file_missing");
        if(spec[@"symlink"]) {
            if(!S_ISLNK(st.st_mode) || ![[fm destinationOfSymbolicLinkAtPath:p error:nil] isEqual:spec[@"symlink"]])fail(@"runtime_link_mismatch");
        } else if(!S_ISREG(st.st_mode) || ![hashFile(p) isEqual:spec[@"sha256"]])fail(@"runtime_file_hash_mismatch");
    }
    NSDirectoryEnumerator *enumerator=[fm enumeratorAtPath:engine];NSString *name;
    while((name=[enumerator nextObject])) {
        struct stat st;if(lstat(join(engine,name).fileSystemRepresentation,&st))fail(@"runtime_file_missing");
        // Finder writes .DS_Store into any folder a user opens; nothing loads it.
        if(S_ISREG(st.st_mode) && [name.lastPathComponent isEqual:@".DS_Store"])continue;
        if(generatedGameApp(name))continue;
        if(!S_ISDIR(st.st_mode) && ![name isEqual:@"runtime.json"] && !files[name])fail(@"runtime_unlisted_file");
    }
    NSMutableArray *requiredFiles=[@[@"bin/wine",@"bin/wineserver",@"config/dxmt.conf",@"lib/external/libd3dshared.dylib",@"lib/wine/x86_64-unix/winemac.so"] mutableCopy];
#ifdef MACVOLVO_GPTK4
    [requiredFiles addObjectsFromArray:@[@"lib/external/D3DMetal.framework/Versions/A/D3DMetal",
        @"lib/wine/x86_64-unix/d3d11.so",@"lib/wine/x86_64-unix/dxgi.so",
        @"lib/wine/x86_64-windows/d3d11.dll",@"lib/wine/x86_64-windows/dxgi.dll"]];
#else
    [requiredFiles addObject:@"lib/wine/x86_64-unix/winemetal.so"];
#endif
    for(NSString *required in requiredFiles)
        if(!files[required])fail(@"runtime_required_component_missing");
    for(NSString *architecture in @[@"x86_64-windows",@"i386-windows"])
        for(NSString *module in @[@"winemac.drv",@"mountmgr.sys",@"nsiproxy.sys",@"kernel32.dll",@"ntdll.dll"])
            if(!files[join(join(@"lib/wine",architecture),module)])fail(@"runtime_required_component_missing");
}
// Each update leaves the runtime it replaced (~0.7 GB). Keep the active and the
// previous one; older runtimes this worker installed are removed.
static void pruneRuntimes(NSString *active, NSString *previous) {
    NSString *directory=join(root,@"runtimes");
    for(NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if([name isEqual:active] || [name isEqual:previous] || !matches(name,@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))continue;
        NSString *path=join(directory,name);struct stat st;
        if(lstat(path.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode) || ![fm fileExistsAtPath:join(path,@"runtime.json")])continue;
        [fm removeItemAtPath:path error:nil];
    }
}
static void installRuntime(NSString *archivePath, NSString *expected, NSString *version, BOOL repair) {
    if(!matches(version,@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") || !matches(expected,@"^[a-f0-9]{64}$"))fail(@"invalid_runtime_identity");
    if(state()[@"active_runtime"] && busy(runtime()))fail(@"close_game_before_maintenance");
    if(![hashFile(archivePath) isEqual:expected])fail(@"archive_hash_mismatch");
    space(6ULL<<30);
    NSString *target=join(join(root,@"runtimes"),version),*stage=join(root,@"incoming-runtime");
    saveStage(@"installing_runtime");
    if([fm fileExistsAtPath:target] && !repair)verifyRuntime(target,version);
    else {
        // Repair extracts a fresh copy from the app's archive and swaps it in;
        // the replaced copy is removed only after the new one verified.
        if([fm fileExistsAtPath:stage] && ![fm removeItemAtPath:stage error:nil])fail(@"staging_cleanup_failed");
        mkdirs(stage);extract(archivePath,stage);verifyRuntime(stage,version);
        NSString *replaced=join(root,@"replaced-runtime");
        if([fm fileExistsAtPath:replaced] && ![fm removeItemAtPath:replaced error:nil])fail(@"staging_cleanup_failed");
        if([fm fileExistsAtPath:target] && ![fm moveItemAtPath:target toPath:replaced error:nil])fail(@"runtime_commit_failed");
        if(![fm moveItemAtPath:stage toPath:target error:nil])fail(@"runtime_commit_failed");
        [fm removeItemAtPath:replaced error:nil];
    }
    NSMutableDictionary *s=state();NSString *previous=s[@"active_runtime"];
    if(previous && ![previous isEqual:version])s[@"previous_runtime"]=previous;
    if(repair)[s removeObjectForKey:@"prepared_runtime"];
    s[@"active_runtime"]=version;s[@"stage"]=@"runtime_ready";writeJSON(s,join(root,@"state.json"));
    pruneRuntimes(version,s[@"previous_runtime"]);
    event(@"runtime_ready",@{@"version":version});
}
static void prepare(void) {
    preflight();NSString *engine=runtime();verifyRuntime(engine,state()[@"active_runtime"]);
    if(busy(engine))fail(@"close_game_before_setup");space(3ULL<<30);
    NSString *prefix=join(root,@"environment");
    NSString *marker=join(root,@"environment-owned.json");
    if([fm fileExistsAtPath:prefix] && ![fm fileExistsAtPath:marker])fail(@"existing_environment_not_owned");
    if(![fm fileExistsAtPath:marker])writeJSON(@{@"schema":@1,@"runtime":state()[@"active_runtime"]},marker);
    saveStage(@"preparing_environment");ownedPreparation=YES;
    // Update registry/drivers without running installed clients' login startup
    // entries. Battle.net must be opened by launchClient with its CEF options.
    if(waitTask(task(join(engine,@"bin/wine"),@[@"wineboot.exe",@"-u",@"-r"],wineEnv(engine),@"wineboot.log"),180))fail(@"environment_initialization_failed");
    if(waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"wineboot-wait.log"),60))fail(@"environment_initialization_busy");
    if(![fm fileExistsAtPath:join(prefix,@"system.reg")])fail(@"environment_registry_missing");
    configureRetina();
    // The player's network choice (portable_network.h), before Steam's installer first goes
    // online, and Steam's scaling (portable_steam.h). Neither stops setup; launches retry.
    configureProxy(engine,proxyDetectionChosen());
    configureScaling(engine);
    if(!registrySaved(engine,60))fail(@"environment_initialization_busy");
    // An update keeps a resolution chosen in the game since the last launch.
    NSInteger width,height;NSString *source;nextResolution(&width,&height,&source,YES);configureDisplay(width,height);
    NSMutableDictionary *s=state();s[@"prepared_runtime"]=s[@"active_runtime"];writeJSON(s,join(root,@"state.json"));
    saveStage(@"environment_ready");ownedPreparation=NO;
}
static NSString *clientPath(void) {return join(steamFolder(),@"steam.exe");}
static void installClient(NSString *installer, NSString *expected) {
    requireRosetta();
    NSString *engine=runtime();if(busy(engine))fail(@"close_game_before_setup");
    if(![fm fileExistsAtPath:join(root,@"environment/system.reg")])fail(@"prepare_environment_first");
    if(!matches(expected,@"^[a-f0-9]{64}$") || ![hashFile(installer) isEqual:expected])fail(@"client_installer_hash_mismatch");
    configureProxy(engine,proxyDetectionChosen());
    // Stage and event names keep Recall's ("battlenet") so the app's state machine carries
    // over; the client is Steam. Its installer runs silently and exits once Steam's files
    // are in place; Steam downloads the rest when it first opens.
    saveStage(@"installing_battlenet");
    NSTask *p=task(join(engine,@"bin/wine"),@[installer,@"/S"],wineEnv(engine),@"steam-installer.log");
    event(@"battlenet_installer_open",@{@"pid":@(p.processIdentifier)});
    if(waitTask(p,600) || ![fm fileExistsAtPath:clientPath()])fail(@"steam_install_failed");
    waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"steam-installer-wait.log"),60);
    event(@"steam_installed",nil);
}
static void closeClient(NSString *gameRunning);
// Ends whatever is left of the Wine session (the update Agent, Wine's own services).
static void endSession(NSString *engine) {
    int code=waitTask(task(join(engine,@"bin/wineserver"),@[@"-k"],wineEnv(engine),@"session-end.log"),15);
    if(code!=0 && code!=1)fail(@"client_close_failed");
    if(waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"session-end-wait.log"),15))fail(@"client_close_failed");
}
/* Apple's Metal Performance HUD (Settings, launch --metal-hud 1) reaches the game through
 * Steam, which starts it with its own environment. MTL_HUD_ELEMENTS lists the HUD's default
 * panel ("gamemode" is undocumented) plus the shader compiler, which shows the game compiling
 * shaders, the cause of a first match's stutters.
 * macOS Game Mode: WINE_GAME_MODE makes Wine start each game from its game app
 * (lib/wine/game-mode/<game>.app, portable_steam.h). launch --game-mode 0 leaves it out. */
static NSMutableDictionary *clientEnvironment(NSMutableDictionary *env, BOOL hud, BOOL gameMode) {
    if(!gameMode)[env removeObjectForKey:@"WINE_GAME_MODE"];
    if(hud)[env addEntriesFromDictionary:@{@"MTL_HUD_ENABLED":@"1",@"MTL_HUD_DISABLE_MENU_BAR":@"1",
        @"MTL_HUD_ELEMENTS":@"device,rosetta,layersize,memory,gamemode,fps,gputime,frameinterval,frameintervalgraph,shaders"}];
    return env;
}
/* Opens Steam; with a game (play), Steam starts it (-applaunch). A running Steam receives
 * the game from a second steam.exe, which hands it over and exits. */
static void launchClient(BOOL diagnostic, NSString *play, NSString *fullscreen, BOOL hud, BOOL gameMode) {
    requireRosetta();
    NSString *engine=runtime();if(![fm fileExistsAtPath:clientPath()])fail(@"battlenet_not_installed");
    const MVGame *game=play ? mvGame(play) : NULL;
    if(play && !game)fail(@"unknown_game");
    if(fullscreen && ![fullscreen isEqual:@"0"] && ![fullscreen isEqual:@"1"])fail(@"invalid_arguments");
    NSArray *existing=sessionProcesses();
    if(diagnostic && existing.count)fail(@"close_game_before_maintenance");
    NSString *displays=displaySignature(),*sessionDisplays=state()[@"session_displays"];
    BOOL displaysChanged=displays && ![displays isEqual:sessionDisplays];
    BOOL running=NO;for(NSDictionary *p in existing)running|=[p[@"kind"] isEqual:@"game"];
    if(running) {
        // Open Steam must focus the client even while a game owns the session.
        // Play keeps the existing game foreground rather than starting a duplicate.
        NSArray *targets=game ? existing : [existing filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"kind == %@",@"client"]];
        focusSession(targets);return;
    }
    if(game && fullscreen) {
        NSDictionary *choice=gameLaunchOptions(NO)[game->key];
        if([choice[@"fullscreen"] boolValue]!=[fullscreen isEqual:@"1"])
            configureGameLaunchOptions(game->key,[choice[@"width"] integerValue],[choice[@"height"] integerValue],fullscreen);
    }
    NSDictionary *choices=gameLaunchOptions(NO),*fitted=gameLaunchOptions(YES),*defaults=steamLaunchDefaults(fitted);
    BOOL needsOptions=NO;
    if(!steamLaunchOptionsNeedUpdate(defaults,&needsOptions))fail(@"steam_launch_options_invalid");
    NSDictionary *s=state();
    BOOL environmentChanged=![s[@"session_hud"] isEqual:@(hud)] || ![s[@"session_game_mode"] isEqual:@(gameMode)];
    BOOL needsWindowFix=existing.count && steamWindowFixNeeded();
    // Steam owns its children's environment and cached launch options. Reopen an idle
    // client cleanly when those change; never edit a live client's account config.
    if(existing.count && (needsOptions || (sessionDisplays && displaysChanged) || environmentChanged || needsWindowFix)) {
        event(needsWindowFix?@"steam_browser_repair":(displaysChanged?@"displays_changed":@"launch_options_changed"),nil);
        closeClient(@"close_game_before_maintenance");existing=@[];
    }
    if(!existing.count) {
        endSession(engine);
        if(!configureSteamLaunchOptions(defaults))fail(@"steam_launch_options_write_failed");
    }
    if(!configureDeadlockRenderer()) {
        if(game && [game->key isEqual:@"deadlock"])fail(@"game_renderer_write_failed");
        event(@"game_renderer_configuration_skipped",@{@"game":@"deadlock"});
    }
    if(game) {
        NSDictionary *choice=choices[game->key],*actual=fitted[game->key];
        if(![choice[@"width"] isEqual:actual[@"width"]] || ![choice[@"height"] isEqual:actual[@"height"]])
            event(@"display_fitted",@{@"game":game->key,@"width":actual[@"width"],@"height":actual[@"height"],@"chosen_width":choice[@"width"],@"chosen_height":choice[@"height"]});
    }
    NSString *config=[NSString stringWithContentsOfFile:join(engine,@"config/dxmt.conf") encoding:NSUTF8StringEncoding error:nil];
    if(!config)fail(@"runtime_missing");
    NSDictionary *base=fitted[@"cs2"];
    config=gamesProfile(canvasProfile(config,[base[@"width"] integerValue],[base[@"height"] integerValue]),fitted);
    if(![config writeToFile:join(root,@"dxmt.conf") atomically:YES encoding:NSUTF8StringEncoding error:nil])fail(@"settings_write_failed");
    makeGameApps(engine);
    NSMutableArray *client=[@[clientPath(),@"-no-cef-sandbox"] mutableCopy];
    if(game) {
        // The same persisted settings apply to both Library and app launches.
        // Keep the browser behind the game to avoid a startup focus transition.
        [client addObjectsFromArray:@[@"-silent",@"-applaunch",game->appID]];
    }
    if(existing.count) {
        configureVoiceMicrophone(engine,nil,YES,NO);
        if(game) {
            [client insertObject:@"-noverifyfiles" atIndex:1];
            // This second Steam is only an IPC request to the existing client.
            // Reap it before another launch can enqueue one; if it hangs, end
            // only this task, leaving Steam, its downloads and the game alone.
            int code=waitTask(task(join(engine,@"bin/wine"),client,clientEnvironment(wineEnv(engine),hud,gameMode),[NSString stringWithFormat:@"steam-play-%@.log",NSUUID.UUID.UUIDString]),15);
            if(code)fail(@"steam_launch_request_failed");
            event(@"game_launch_requested",@{@"game":game->key});
        } else focusSession(existing);
        return;
    }
    configureRetina();
    // Setup applies these; a launch puts back any that went missing. The voice step below
    // waits for Wine's server.
    configureProxy(engine,proxyDetectionChosen());
    configureScaling(engine);
    if(steamWindowFix(engine))[client insertObject:@"-noverifyfiles" atIndex:1];
    configureVoiceMicrophone(engine,nil,YES,YES);
    NSMutableDictionary *session=state();
    if(displays)session[@"session_displays"]=displays;
    session[@"session_hud"]=@(hud);session[@"session_game_mode"]=@(gameMode);writeJSON(session,join(root,@"state.json"));
    NSDictionary *env=clientEnvironment(diagnostic?diagnosticEnvironment(engine):wineEnv(engine),hud,gameMode);
    NSTask *p=task(join(engine,@"bin/wine"),client,env,[NSString stringWithFormat:@"steam-%@.log",NSUUID.UUID.UUIDString]);
    saveStage(@"battlenet_started");event(@"battlenet_open",@{@"pid":@(p.processIdentifier)});
    if(game)event(@"game_launch_requested",@{@"game":game->key});
}

/* Settings › Advanced. Steam and the games carry both settings from when they start,
 * so both must be closed. The registry changes first; then the choice is saved for setup
 * and launches to keep. Without APPLY nothing changes: what would is reported. */
static void advancedSetting(NSString *name, BOOL on, BOOL apply) {
    BOOL korean=NO;
    if(!apply) {
        if(korean)configureKoreanCertificate(nil,on,NO);else configureProxy(nil,on);
        return;
    }
    // Before setup has made the Windows environment, the choice waits for prepare.
    if([fm fileExistsAtPath:join(root,@"environment/system.reg")]) {
        NSString *engine=runtime();
        if(sessionProcesses().count)fail(@"close_game_before_maintenance");
        if(!(korean ? configureKoreanCertificate(engine,on,NO) : configureProxy(engine,on)))fail(@"setting_change_failed");
        registrySaved(engine,6);
    }
    NSMutableDictionary *s=state();s[name]=@(on);writeJSON(s,join(root,@"state.json"));
    event(@"setting_saved",@{@"name":name,@"enabled":@(on)});
}
// Refuses while a game runs. Steam must flush its launch options before any
// maintenance edits localconfig.vdf; use its normal shutdown request.
static void closeClient(NSString *gameRunning) {
    if(!(matches(state()[@"active_runtime"],@"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") && [fm fileExistsAtPath:join(join(join(root,@"runtimes"),state()[@"active_runtime"]),@"runtime.json")]))return;
    NSString *engine=runtime();BOOL closed=NO;
    for(int attempt=0;attempt<20 && !closed;attempt++) {
        if(membershipCache)[membershipCache removeAllObjects];
        NSArray *rows=sessionProcesses();NSMutableArray *clients=[NSMutableArray array];
        for(NSDictionary *p in rows) {if([p[@"kind"] isEqual:@"game"])fail(gameRunning);[clients addObject:p];}
        if(!clients.count) {closed=YES;break;}
        if(attempt==0) {
            event(@"closing_client",nil);
            waitTask(task(join(engine,@"bin/wine"),@[clientPath(),@"-shutdown"],wineEnv(engine),@"steam-shutdown.log"),10);
        }
        [NSThread sleepForTimeInterval:1];
    }
    if(!closed)fail(@"client_close_failed");
    // Steam can exit before its browser, overlay and Wine services. Do not
    // report the installation idle (or move it during uninstall) until those
    // have stopped too. Recheck in case Steam started a game while closing.
    for(NSDictionary *p in sessionProcesses())if([p[@"kind"] isEqual:@"game"])fail(gameRunning);
    endSession(engine);
}
static void uninstall(void) {
    // Everything this app created lives under the owned root: the Wine
    // environment holding Steam and its games, runtimes, downloads, logs
    // and caches. ownRoot already refused any directory without the marker.
    closeClient(@"close_game_before_uninstall");
    // Move, never delete: the folder is recoverable from the Trash with Put
    // Back. On the same volume this is a rename even for a full game install.
    NSURL *trashed=nil;NSError *error=nil;
    if(![fm trashItemAtURL:[NSURL fileURLWithPath:root] resultingItemURL:&trashed error:&error])fail(@"uninstall_move_failed");
    event(@"uninstalled",@{@"trashed":trashed.path ?: @""});
}
static void discardUnused(void) {
    // Switching install location before anything was installed: remove only
    // the empty scaffold ownRoot made (plus setup check logs). Anything else,
    // including any installation state, keeps the folder untouched.
    if([fm fileExistsAtPath:join(root,@"state.json")])fail(@"location_in_use");
    NSSet *scaffold=[NSSet setWithArray:@[MV_OWNER_MARKER,@"setup.lock",@".DS_Store",@"runtimes",@"downloads",@"logs",@"home",@"tmp",@"cache"]];
    for(NSString *name in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if(![scaffold containsObject:name])fail(@"location_in_use");
        struct stat st;if(lstat(join(root,name).fileSystemRepresentation,&st))fail(@"location_in_use");
        if(!S_ISDIR(st.st_mode))continue;
        for(NSString *child in [fm contentsOfDirectoryAtPath:join(root,name) error:nil])
            if(!([name isEqual:@"logs"] && [child hasSuffix:@".log"]) && ![child isEqual:@".DS_Store"])fail(@"location_in_use");
    }
    close(lockFD);lockFD=-1;
    if(![fm removeItemAtPath:root error:nil])fail(@"location_cleanup_failed");
    event(@"location_released",nil);
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    fm=NSFileManager.defaultManager;signal(SIGTERM,cancelled);signal(SIGINT,cancelled);
    @try {
        if(argc<2)fail(@"command_required");NSString *command=@(argv[1]);NSMutableDictionary *options=[NSMutableDictionary dictionary];
        for(int i=2;i<argc;i+=2) {if(i+1>=argc || strncmp(argv[i],"--",2))fail(@"invalid_arguments");options[@(argv[i]+2)]=@(argv[i+1]);}
        NSString *defaultRoot=join([fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path,MV_DATA_FOLDER);
        monitorMode=[command isEqual:@"watch"];
        ownRoot(options[@"root"] ?: defaultRoot);
        if([command isEqual:@"preflight"])preflight();
        else if([command isEqual:@"status"]) {
            // The resolution the game opens at next on the main display.
            NSInteger width,height;NSString *source;nextResolution(&width,&height,&source,NO);
            NSMutableDictionary *next=[@{@"width":@(width),@"height":@(height),@"from_game":@([source isEqual:@"game"]),@"per_display":@(displayMemory(state()))} mutableCopy];
            if(mainScreen())next[@"screen"]=mainScreen();
            event(@"status",@{@"state":state(),@"display_next":next,@"game_launch_options":gameLaunchOptions(NO),@"battlenet_installed":@([fm fileExistsAtPath:clientPath()]),@"game_installed":@((BOOL)(installedGames().count>0)),@"games":installedGames(),@"nexon_build":@NO,@"free_bytes":@(freeBytes())});
        }
        else if([command isEqual:@"onboarded"]) { NSMutableDictionary *s=state();s[@"onboarding_complete"]=@YES;writeJSON(s,join(root,@"state.json"));event(@"onboarding_complete",nil); }
        else if([command isEqual:@"session"])event(@"session",@{@"processes":sessionProcesses()});
        else if([command isEqual:@"watch"])watchClient();
        else if([command isEqual:@"display"]) {
            // 0.1.x apps sent only a height (1080 or 1200, 1920 wide).
            NSString *width=options[@"width"] ?: @"1920",*height=options[@"height"] ?: @"";
            if(!matches(width,@"^[0-9]{3,5}$") || !matches(height,@"^[0-9]{3,5}$") ||
               !gameResolution(width.integerValue,height.integerValue))fail(@"unsupported_resolution");
            if(options[@"game"])configureGameLaunchOptions(options[@"game"],width.integerValue,height.integerValue,options[@"fullscreen"]);
            else configureDisplay(width.integerValue,height.integerValue);
        }
        else if([command isEqual:@"display-memory"]) {
            // Settings › Remember a resolution for each display.
            NSString *enabled=options[@"enabled"];
            if(![enabled isEqual:@"0"] && ![enabled isEqual:@"1"])fail(@"invalid_arguments");
            NSMutableDictionary *s=state();s[@"display_memory"]=@([enabled isEqual:@"1"]);writeJSON(s,join(root,@"state.json"));
            event(@"display_memory",@{@"enabled":@([enabled isEqual:@"1"])});
        }
        else if([command isEqual:@"repair-retina"])configureRetina();
        // Support and tests: the microphone launch points Wine at (portable_voice.h). --uid names one
        // instead of asking Core Audio ("none": macOS's default); --apply 0 only reports.
        else if([command isEqual:@"voice-microphone"]) {
            BOOL apply=![options[@"apply"] isEqual:@"0"];
            configureVoiceMicrophone(apply ? runtime() : nil,options[@"uid"],apply,NO);
        }
        // Settings › Advanced: --proxy-detect 0|1 (automatic proxy detection) and --enabled 0|1
        // (Korean account support). --apply 0 only reports what would change (support and tests).
        else if([command isEqual:@"network"] || [command isEqual:@"korean-support"]) {
            BOOL korean=[command isEqual:@"korean-support"];
            NSString *value=options[korean ? @"enabled" : @"proxy-detect"];
            if(![value isEqual:@"0"] && ![value isEqual:@"1"])fail(@"invalid_arguments");
            advancedSetting(korean ? @"korean_support" : @"proxy_auto_detect",[value isEqual:@"1"],![options[@"apply"] isEqual:@"0"]);
        }
        else if([command isEqual:@"restore-candidate"]) {
            configureRetina();
            // The qualified baseline's resolution unless the player has chosen one.
            NSInteger width,height;NSString *source;
            if(state()[@"display_height"])nextResolution(&width,&height,&source,YES);else chosenResolution(&width,&height);
            configurePreferences(width,height,width,height,YES);
        }
        else if([command isEqual:@"download"])event(@"download_complete",@{@"file":[download(options[@"url"],options[@"sha256"]) lastPathComponent]});
        else if([command isEqual:@"install-runtime"])installRuntime(options[@"archive"] ?: download(options[@"url"],options[@"sha256"]),options[@"sha256"],options[@"version"],[options[@"repair"] isEqual:@"1"]);
        else if([command isEqual:@"verify"]) {verifyRuntime(runtime(),state()[@"active_runtime"]);event(@"runtime_verified",nil);}
        else if([command isEqual:@"prepare"])prepare();
        else if([command isEqual:@"install-battlenet"])installClient(options[@"installer"] ?: download(options[@"url"],options[@"sha256"]),options[@"sha256"]);
        // --game cs2|deadlock starts that game through Steam (portable_steam.h); without it
        // only Steam opens. --play 1 (Recall's) means the first installed game.
        // --fullscreen 0 starts the game in a window (Fullscreen toggle per game); on by default.
        // --metal-hud 1 shows Apple's Metal Performance HUD over the game (Settings); off by default.
        // --game-mode 0 starts the game without macOS Game Mode (hidden app default); on by default.
        else if([command isEqual:@"launch"]) {
            NSString *game=options[@"game"];
            if(!game && [options[@"play"] isEqual:@"1"])game=installedGames().firstObject ?: @"cs2";
            launchClient(NO,game,options[@"fullscreen"],[options[@"metal-hud"] isEqual:@"1"],![options[@"game-mode"] isEqual:@"0"]);
        }
        else if([command isEqual:@"diagnostic-launch"])launchClient(YES,options[@"game"],options[@"fullscreen"],[options[@"metal-hud"] isEqual:@"1"],![options[@"game-mode"] isEqual:@"0"]);
        // Support and tests: what a launch with --enabled 0|1 (and --sharpening) sets up for MetalFX
        // upscaling (portable_metalfx.h); --apply 0 only reports.
        else if([command isEqual:@"metalfx"]) {
            BOOL apply=![options[@"apply"] isEqual:@"0"];
            if(![options[@"enabled"] isEqual:@"0"] && ![options[@"enabled"] isEqual:@"1"])fail(@"invalid_arguments");
            if(apply && sessionProcesses().count)fail(@"close_game_before_maintenance");
            NSString *amount=nil;configureMetalFX(runtime(),[options[@"enabled"] isEqual:@"1"],options[@"sharpening"] ?: @"off",apply,&amount);
        }
        else if([command isEqual:@"close-client"]) {closeClient(@"close_game_before_update");event(@"client_closed",nil);}
        else if([command isEqual:@"parity-report"])event(@"parity_report",parityReport(runtime(),wineEnv(runtime())));
        else if([command isEqual:@"uninstall"])uninstall();
        else if([command isEqual:@"discard-unused"])discardUnused();
        else if([command isEqual:@"stop"]) {endSession(runtime());event(@"environment_stopped",nil);}
        else fail(@"unknown_command");
        if(lockFD>=0)close(lockFD);return 0;
    } @catch(NSException *exception) {
        if(cancelRequested && ownedPreparation) {
            // There was no client/game when this preparation began. Stop only
            // the helper processes it started in this owned environment.
            cancelRequested=0;
            @try { NSString *engine=runtime();waitTask(task(join(engine,@"bin/wineserver"),@[@"-k"],wineEnv(engine),@"cancel-prepare.log"),15);waitTask(task(join(engine,@"bin/wineserver"),@[@"-w"],wineEnv(engine),@"cancel-wait.log"),15); } @catch(NSException *ignored) { (void)ignored; }
        }
        event(@"error",@{@"code":[exception.name isEqual:@"SetupError"]?exception.reason:@"unexpected_setup_error"});
        if(lockFD>=0)close(lockFD);return 1;
    }
}}
