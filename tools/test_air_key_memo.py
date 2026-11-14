#!/usr/bin/env python3
"""The sha256 key of an AIR text is computed once per text, not once per function object.

nvmtl_function_air_key keeps its answer on the function object, but a client that makes a new function for every use
never finds it there. VideoToolbox's pixel-transfer session does that for each image it converts: a sample of
DisplaysExt while System Settings > Displays opened (driver 3.0, RTX 5060 Ti, macOS 26.7.2) had 146 of the 626 samples
of one thumbnail in nvmtl_pipeline_key_log, 119 of them in CC_SHA256 over the whole text and 22 in its UTF-8
conversion. The key is now also kept per AIR string.

This compiles the production function out of NVMTLObjects.m with CC_SHA256 counted and asks:

  same    two functions over one AIR string: one hash, the same key
  equal   a third function over an equal string that is another object: still one hash
  value   the key is the first 8 bytes of the text's sha256
  other   a different text: a second hash and a different key
  empty   a function with no AIR: key 0, no hash
  control the same questions asked of v3.0's function hash once per function (the control that must fire)"""
import hashlib
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REL = "plugin/NVMTLObjects.m"
fails = 0


def arm(name, ok, detail=""):
    global fails
    fails += not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f" ({str(detail).strip()[-500:]})"))


def cut(src):
    end = src.index("uint64_t nvmtl_function_air_key(id f)")
    memo = src.find("static NSMapTable<NSString *, NSNumber *> *g_airkey_memo;")
    start = memo if 0 <= memo < end else end
    return src[start:src.index("static void nvmtl_heap_register(", end)]


HARNESS = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <os/lock.h>
#include <CommonCrypto/CommonDigest.h>
static int g_hashes;
static unsigned char *counted_sha256(const void *d, CC_LONG n, unsigned char *md) { g_hashes++; return CC_SHA256(d, n, md); }
#define CC_SHA256 counted_sha256
@interface NVMTLFunction : NSObject { @public NSString *_air; }
@end
@implementation NVMTLFunction
@end
%s
static NVMTLFunction *fn(NSString *air) { NVMTLFunction *f = [NVMTLFunction new]; f->_air = air; return f; }
int main(void) { @autoreleasepool {
    NSMutableString *a = [NSMutableString string];
    for (int i = 0; i < 20000; i++) [a appendFormat:@"define void @k%%d() { ret void }\n", i];
    NSString *copy = [NSString stringWithUTF8String:a.UTF8String];
    NVMTLFunction *f1 = fn(a), *f2 = fn(a), *f3 = fn(copy), *f4 = fn([a stringByAppendingString:@"; other\n"]);
    unsigned long long k1 = nvmtl_function_air_key(f1); printf("after1 %%d\n", g_hashes);
    unsigned long long k1b = nvmtl_function_air_key(f1); printf("again1 %%d\n", g_hashes);
    unsigned long long k2 = nvmtl_function_air_key(f2); printf("after2 %%d\n", g_hashes);
    unsigned long long k3 = nvmtl_function_air_key(f3); printf("after3 %%d\n", g_hashes);
    unsigned long long k4 = nvmtl_function_air_key(f4); printf("after4 %%d\n", g_hashes);
    unsigned long long k0 = nvmtl_function_air_key(fn(nil)); printf("after0 %%d\n", g_hashes);
    printf("keys %%016llx %%016llx %%016llx %%016llx %%016llx %%016llx\n", k1, k1b, k2, k3, k4, k0);
    printf("notfn %%016llx\n", (unsigned long long)nvmtl_function_air_key(@"x"));
    fwrite(a.UTF8String, 1, strlen(a.UTF8String), stderr);
} return 0; }
'''


def run(src, work, tag):
    m = work / f"{tag}.m"
    m.write_text(HARNESS % cut(src))
    cc = subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O1", "-o", str(work / tag), str(m), "-framework", "Foundation"],
                        capture_output=True, text=True)
    if cc.returncode:
        return None, cc.stderr
    p = subprocess.run([str(work / tag)], capture_output=True)
    out = dict(l.split(None, 1) for l in p.stdout.decode().splitlines())
    return out, p.stderr


with tempfile.TemporaryDirectory() as d:
    work = pathlib.Path(d)
    out, text = run((ROOT / REL).read_text(), work, "now")
    arm("the production function compiles out of NVMTLObjects.m", out is not None, text)
    if out is None:
        sys.exit(1)
    keys = out["keys"].split()
    want = hashlib.sha256(text).hexdigest()[:16]
    arm("first function over a text: one hash", out["after1"] == "1", out)
    arm("the same function asked again: no new hash", out["again1"] == "1" and keys[1] == keys[0], out)
    arm("same: a second function over the same AIR string does not hash it again", out["after2"] == "1", out)
    arm("  and gets the same key", keys[2] == keys[0], keys)
    arm("equal: a function over an equal string in another object does not hash it again", out["after3"] == "1", out)
    arm("  and gets the same key", keys[3] == keys[0], keys)
    arm("value: the key is the first 8 bytes of the text's sha256", keys[0] == want, (keys[0], want))
    arm("other: a different text is hashed", out["after4"] == "2", out)
    arm("  and has a different key", keys[4] != keys[0], keys)
    arm("empty: a function with no AIR has key 0 and is not hashed", keys[5] == "0" * 16 and out["after0"] == "2", out)
    arm("an object that is not a function has key 0", out["notfn"] == "0" * 16, out)

    old = subprocess.run(["git", "-C", str(ROOT), "show", f"v3.0:{REL}"], capture_output=True, text=True)
    arm("v3.0's source can be read for the control (full clone needed)", old.returncode == 0, old.stderr)
    if old.returncode == 0:
        o, text0 = run(old.stdout, work, "v30")
        arm("control: v3.0's function compiles in the same harness", o is not None, text0)
        if o is not None:
            arm("control: v3.0 hashes the text once per function object (3 for three functions over one text)",
                o["after3"] == "3", o)
            arm("control: v3.0 gives the same keys", o["keys"].split() == keys, (o["keys"], keys))

print(f"{fails} failed")
sys.exit(1 if fails else 0)
