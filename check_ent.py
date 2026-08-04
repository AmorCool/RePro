#!/usr/bin/env python3
import struct, zlib, sys, gzip, lzma

DEB = r"C:\Users\Administrator\WorkBuddy\reprovison-cn\RePro\jp.soh.reprovision_1.1.68.release_roothide-iphoneos-arm64.deb"

def parse_ar(data):
    assert data[:8] == b"!<arch>\n"
    off = 8; members = {}
    while off < len(data):
        if data[off:off+1] == b"\n":
            off += 1; continue
        hdr = data[off:off+60]
        name = hdr[0:16].decode().strip().strip("/")
        size = int(hdr[48:58].decode().strip())
        off += 60
        members[name] = data[off:off+size]
        off += size + (size & 1)
    return members

with open(DEB, "rb") as f:
    data = f.read()
members = parse_ar(data)
data_tar = [v for k,v in members.items() if k.startswith("data.tar")][0]
if data_tar[:2] == b"\x1f\x8b":
    raw = gzip.decompress(data_tar)
else:
    raw = lzma.decompress(data_tar)

def find_all(raw, suffixes):
    off=0; n=len(raw); out={}
    while off+512<=n:
        hdr=raw[off:off+512]
        if hdr[0:1]==b"\x00": break
        name=hdr[0:100].split(b"\x00")[0].decode(errors="replace")
        s=hdr[124:136].split(b"\x00")[0].strip().decode(errors="replace").replace("\x00","").strip()
        try: size=int(s,8) if s else 0
        except: size=0
        off+=512
        for suf in suffixes:
            if suf in name:
                out[name]=raw[off:off+size]
        off+=((size+511)//512)*512
    return out

def get_thin(b):
    """Given a possibly-fat Mach-O, return the arm64 thin slice bytes."""
    magic = struct.unpack(">I", b[:4])[0]
    if magic in (0xcafebabe, 0xcafebabf):  # FAT (either endian)
        nfat = struct.unpack(">I", b[4:8])[0]
        for i in range(nfat):
            o = 8 + i*20
            ct, cs, so, ss, al = struct.unpack(">IIIII", b[o:o+20])
            if ct == 0x0100000c:  # ARM64
                return b[so:so+ss]
        return b
    return b

def parse_entitlements(thin):
    magic = struct.unpack("<I", thin[:4])[0]
    if magic == 0xfeedfacf:           # 64-bit, little-endian storage
        en="<"; m64=True
    elif magic == 0xcffaedfe:         # 64-bit, big-endian storage (swapped)
        en=">"; m64=True
    elif magic == 0xfeedface:         # 32-bit, little-endian storage
        en="<"; m64=False
    elif magic == 0xcefaedfe:         # 32-bit, big-endian storage (swapped)
        en=">"; m64=False
    elif magic in (0xcafebabe, 0xcafebabf):
        return None, "still FAT (slice not extracted), magic %x" % magic
    else:
        return None, "unknown magic %x" % magic
    ncmds = struct.unpack(en+"I", thin[16:20])[0]
    print("  magic=%#x en=%s m64=%s ncmds=%d" % (magic, en, m64, ncmds))
    off = 32 if m64 else 28
    cmds=[]
    for i in range(ncmds):
        if off+8 > len(thin):
            break
        cmd, cmdsize = struct.unpack(en+"II", thin[off:off+8])
        if cmdsize == 0:
            break
        cmds.append(cmd)
        if cmd == 0x1d:  # LC_CODE_SIGNATURE
            _, _, doff, dsize = struct.unpack(en+"IIII", thin[off:off+16])
            blob = thin[doff:doff+dsize]
            smagic, slen, count = struct.unpack(">III", blob[0:12])
            ents=[]
            for j in range(count):
                etype, eoff = struct.unpack(">II", blob[12+j*8:12+j*8+8])
                ent = blob[eoff:]
                bm, blen = struct.unpack(">II", ent[0:8])
                body = ent[8:blen]
                if etype == 0x00000005:  # entitlements
                    ents.append(body.decode("utf-8","replace"))
            return cmds, ents
        off += cmdsize
    return cmds, None

bins = find_all(raw, ["repro-signingd","RePro.app/RePro","repro-helper","repro-profiledaemon"])
for nm, bd in bins.items():
    if not bd: continue
    thin = get_thin(bd)
    cmds, ents = parse_entitlements(thin)
    print("="*70)
    print("FILE:", nm, "thin_size=", len(thin))
    if isinstance(cmds, str):
        print("  parse error:", cmds)
        continue
    print("  ncmds=", len(cmds), " cmds sample=", cmds[:12])
    has_sig = 0x1d in cmds
    print("  HAS_LC_CODE_SIGNATURE =", has_sig)
    if ents:
        for e in ents:
            print("  --- ENTITLEMENTS ---")
            print(e)
    elif has_sig:
        print("  (has signature but no entitlements blob?)")
