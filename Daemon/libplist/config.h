#ifndef CONFIG_H
#define CONFIG_H

/* 手动交叉编译（iOS arm64）用的精简 config.h。
   原工程由 autotools ./configure 生成此文件，libplist 的 plist.h 会无条件
   #include <config.h>，因此我们提供一个最小实现。 */

#define HAVE_CONFIG_H 1

/* 时间相关函数在 iOS 上均可用 */
#define HAVE_FVISIBILITY 1
#define HAVE_GMTIME_R 1
#define HAVE_LOCALTIME_R 1
#define HAVE_STRPTIME 1
#define HAVE_TIMEGM 1
#define HAVE_TM_TM_GMTOFF 1
#define HAVE_TM_TM_ZONE 1

#define SIZEOF_VOID_P 8

#endif /* CONFIG_H */
