import io, os, re, pathlib

root = pathlib.Path('.')
excludes = {'Reborn', '.git', 'build', 'ci_run_', 'CydiaPackages', '.workbuddy', '_dl'}

files_to_process = []
for p in root.rglob('*'):
    if p.is_dir() or any(x in str(p) for x in excludes):
        continue
    if p.suffix in ('.m','.h','.swift','.plist','.py','.yml','.sh','.json','.xml','.entitlements'):
        files_to_process.append(str(p))
    elif p.name in ('control','postinst','prerm'):
        files_to_process.append(str(p))

replacements = [
    ('cn.analy.resign', 'cn.analy.resign'),
    ('cn.analy.resign', 'cn.analy.resign'),
    ('/var/mobile/Library/Resign', '/var/mobile/Library/Resign'),
    ('cn.analy.resign.fixedfw', 'cn.analy.resign.fixedfw'),
    ('cn.analy.resign.profile-install-request', 'cn.analy.resign.profile-install-request'),
    ('cn.analy.resign.profile-manage-request', 'cn.analy.resign.profile-manage-request'),
    ('cn.analy.resign.signingd-config-updated', 'cn.analy.resign.signingd-config-updated'),
    ('cn.analy.resign.daemon-request-resign', 'cn.analy.resign.daemon-request-resign'),
    ('cn.analy.resign.schedule-resign', 'cn.analy.resign.schedule-resign'),
    ('cn.analy.resign.signing-complete', 'cn.analy.resign.signing-complete'),
    ('cn.analy.resign.bypass-3app-request', 'cn.analy.resign.bypass-3app-request'),
    ('cn.analy.resign.diagnostic', 'cn.analy.resign.diagnostic'),
    ('"cn.analy.resign"', '"cn.analy.resign"'),
    ('cn.analy.resign.*', 'cn.analy.resign.*'),
    ('"cn.analy.resign.bridge"', '"cn.analy.resign.bridge"'),
    ('group.cn.analy.resign.ios', 'group.cn.analy.resign.ios'),
    ('iCloud.cn.analy.resign.ios', 'iCloud.cn.analy.resign.ios'),
    ('AAAAAAAAAA.cn.analy.resign.ios', 'AAAAAAAAAA.cn.analy.resign.ios'),
]

count = 0
for fp in files_to_process:
    try:
        orig = io.open(fp, encoding='utf-8').read()
    except:
        continue
    s = orig
    for old, new in replacements:
        s = s.replace(old, new)
    if s != orig:
        io.open(fp, 'w', encoding='utf-8', newline='').write(s)
        count += 1

print(f'修改了 {count} 个文件')

renames = [
    ('Resources/cn.analy.resign.signingd.plist', 'Resources/cn.analy.resign.signingd.plist'),
    ('Resources/cn.analy.resign.profiledaemon.plist', 'Resources/cn.analy.resign.profiledaemon.plist'),
]
for old, new in renames:
    if os.path.exists(old):
        os.rename(old, new)
        print(f'重命名: {old} -> {new}')

for variant in ['roothide','rootless','rootful']:
    cp = f'Packages/{variant}/DEBIAN/control'
    if os.path.exists(cp):
        c = io.open(cp, encoding='utf-8').read()
        if 'Package: cn.analy.resign' in c:
            c = c.replace('Package: cn.analy.resign', 'Package: cn.analy.resign')
            io.open(cp, 'w', encoding='utf-8', newline='').write(c)
            print(f'control Package 修改: {cp}')

print('done')
