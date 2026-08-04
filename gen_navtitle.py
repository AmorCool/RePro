from PIL import Image, ImageDraw, ImageFont

FONT = "C:/Windows/Fonts/Gabriola.ttf"
OUTDIR = "App/Sources/App/Assets.xcassets/NavTitle.imageset"

# 设计基准尺寸（作为 @3x）
W, H = 1024, 256
text = "ReSign"
font_size = 190

font = ImageFont.truetype(FONT, font_size)

# 1) 在基准画布上测量并严格垂直居中
base = Image.new("L", (W, H), 0)
bd = ImageDraw.Draw(base)
bbox = bd.textbbox((0, 0), text, font=font)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]

# 水平居中 + 垂直居中（关键：用 bbox 实际包围盒计算，消除字体内部上下留白）
x = (W - tw) // 2 - bbox[0]
y = (H - th) // 2 - bbox[1]

# 2) 生成白色文字 mask（透明背景）
mask = Image.new("L", (W, H), 0)
ImageDraw.Draw(mask).text((x, y), text, font=font, fill=255)

# 3) 生成蓝紫渐变图层（左蓝 -> 右紫）
grad = Image.new("RGBA", (W, H), (0, 0, 0, 0))
gd = ImageDraw.Draw(grad)
for i in range(W):
    t = i / (W - 1)
    r = int(79 + (176 - 79) * t)    # #4F7CFF -> #B06BFF
    g = int(124 + (107 - 124) * t)
    b = int(255 + (255 - 255) * t)
    gd.line([(i, 0), (i, H)], fill=(r, g, b, 255))

# 4) 用 mask 合成渐变文字
out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
out.paste(grad, (0, 0), mask)

# 5) 导出三档（@1x / @2x / @3x）
out.save(f"{OUTDIR}/NavTitle@3x.png")
out.resize((W * 2 // 3, H * 2 // 3), Image.LANCZOS).save(f"{OUTDIR}/NavTitle@2x.png")
out.resize((W // 3, H // 3), Image.LANCZOS).save(f"{OUTDIR}/NavTitle.png")

print("NavTitle 重新生成完成：文字严格垂直居中")
