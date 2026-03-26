#!/usr/bin/env python3
"""Generate App Store promotional screenshots for SplitCam - V2 Marketing Optimized"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os
import math

OUT_W, OUT_H = 1290, 2796

screenshots = [
    {
        "file": "IMG_4079.PNG",
        "title": "一部手机",
        "title2": "两个视角",
        "subtitle": "前后摄像头同时拍摄",
        "gradient_colors": [(70, 120, 255), (160, 80, 255), (255, 100, 180)],  # blue→purple→pink
        "phone_scale": 0.78,
    },
    {
        "file": "IMG_4086.PNG",
        "title": "记录生活的",
        "title2": "另一面",
        "subtitle": "画中画 自由拖拽缩放",
        "gradient_colors": [(100, 60, 255), (180, 60, 220), (255, 80, 160)],  # purple→magenta→pink
        "phone_scale": 0.78,
    },
    {
        "file": "IMG_4093.PNG",
        "title": "合拍",
        "title2": "让回忆更完整",
        "subtitle": "导入视频 同框录制",
        "gradient_colors": [(60, 180, 220), (80, 120, 255), (140, 80, 255)],  # cyan→blue→purple
        "phone_scale": 0.78,
    },
    {
        "file": "IMG_4089.PNG",
        "title": "多种布局",
        "title2": "随心切换",
        "subtitle": "上下 · 左右 · 画中画 · 多比例",
        "gradient_colors": [(255, 120, 100), (255, 80, 160), (180, 60, 220)],  # coral→pink→purple
        "phone_scale": 0.78,
    },
]

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(BASE_DIR, "appstore_screenshots_v2")
os.makedirs(OUT_DIR, exist_ok=True)


def create_gradient_3color(size, colors):
    """Create a smooth 3-color vertical gradient"""
    img = Image.new("RGB", size)
    draw = ImageDraw.Draw(img)
    c1, c2, c3 = colors
    half = size[1] // 2
    for y in range(size[1]):
        if y < half:
            ratio = y / half
            r = int(c1[0] + (c2[0] - c1[0]) * ratio)
            g = int(c1[1] + (c2[1] - c1[1]) * ratio)
            b = int(c1[2] + (c2[2] - c1[2]) * ratio)
        else:
            ratio = (y - half) / half
            r = int(c2[0] + (c3[0] - c2[0]) * ratio)
            g = int(c2[1] + (c3[1] - c2[1]) * ratio)
            b = int(c2[2] + (c3[2] - c2[2]) * ratio)
        draw.line([(0, y), (size[0], y)], fill=(r, g, b))
    return img


def add_glow(bg, center_x, center_y, radius, color, alpha=60):
    """Add a soft glow circle for depth"""
    glow = Image.new("RGBA", bg.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    for r in range(radius, 0, -2):
        a = int(alpha * (r / radius) ** 0.5)
        glow_draw.ellipse(
            [center_x - r, center_y - r, center_x + r, center_y + r],
            fill=(color[0], color[1], color[2], a),
        )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=40))
    return Image.alpha_composite(bg, glow)


def get_font(size, bold=False):
    """Get system font"""
    font_paths = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Supplemental/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
    ]
    for fp in font_paths:
        if os.path.exists(fp):
            try:
                # index 0=Regular, 1=Medium, 2=Semibold, 3=Bold (for PingFang)
                idx = 3 if bold else 1
                return ImageFont.truetype(fp, size, index=idx)
            except Exception:
                try:
                    idx = 1 if bold else 0
                    return ImageFont.truetype(fp, size, index=idx)
                except Exception:
                    try:
                        return ImageFont.truetype(fp, size)
                    except Exception:
                        continue
    return ImageFont.load_default()


def add_phone_frame(screenshot, target_w, target_h, corner_radius=44):
    """Resize screenshot with rounded corners and subtle border"""
    img = screenshot.copy().resize((target_w, target_h), Image.LANCZOS)

    mask = Image.new("L", (target_w, target_h), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        [(0, 0), (target_w - 1, target_h - 1)],
        radius=corner_radius,
        fill=255,
    )

    output = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    img_rgba = img.convert("RGBA")
    output.paste(img_rgba, (0, 0), mask)

    # White border for contrast
    border_draw = ImageDraw.Draw(output)
    border_draw.rounded_rectangle(
        [(0, 0), (target_w - 1, target_h - 1)],
        radius=corner_radius,
        outline=(255, 255, 255, 120),
        width=4,
    )

    return output


def draw_text_with_shadow(draw, xy, text, font, fill, shadow_offset=4, shadow_alpha=60):
    """Draw text with a soft shadow for depth"""
    x, y = xy
    # Shadow
    shadow_color = (0, 0, 0, shadow_alpha)
    draw.text((x + shadow_offset, y + shadow_offset), text, fill=shadow_color, font=font)
    # Main text
    draw.text(xy, text, fill=fill, font=font)


def generate_screenshot(config, index):
    """Generate one promotional screenshot"""
    # Gradient background
    bg = create_gradient_3color((OUT_W, OUT_H), config["gradient_colors"])
    bg = bg.convert("RGBA")

    # Add soft glow circles for depth
    c = config["gradient_colors"][1]
    bg = add_glow(bg, OUT_W // 3, int(OUT_H * 0.3), 500, (255, 255, 255), alpha=25)
    bg = add_glow(bg, int(OUT_W * 0.7), int(OUT_H * 0.6), 400, c, alpha=20)

    # Load and frame screenshot
    img_path = os.path.join(BASE_DIR, config["file"])
    screenshot = Image.open(img_path)

    phone_w = int(OUT_W * config["phone_scale"])
    phone_h = int(phone_w * screenshot.height / screenshot.width)
    max_phone_h = int(OUT_H * 0.65)
    if phone_h > max_phone_h:
        phone_h = max_phone_h
        phone_w = int(phone_h * screenshot.width / screenshot.height)

    phone_img = add_phone_frame(screenshot, phone_w, phone_h, corner_radius=40)

    # Shadow behind phone (deeper, more spread)
    shadow_spread = 50
    shadow = Image.new("RGBA", (phone_w + shadow_spread * 2, phone_h + shadow_spread * 2), (0, 0, 0, 0))
    shadow_rect = Image.new("RGBA", (phone_w, phone_h), (0, 0, 0, 80))
    shadow.paste(shadow_rect, (shadow_spread, shadow_spread))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=30))

    # Phone position - centered, bottom area
    phone_x = (OUT_W - phone_w) // 2
    phone_y = OUT_H - phone_h - int(OUT_H * 0.04)

    bg.paste(shadow, (phone_x - shadow_spread, phone_y - shadow_spread + 20), shadow)
    bg.paste(phone_img, (phone_x, phone_y), phone_img)

    # === TEXT AREA ===
    draw = ImageDraw.Draw(bg)

    # Large title (two lines for impact)
    title_font = get_font(120, bold=True)
    subtitle_font = get_font(52, bold=False)

    text_y = int(OUT_H * 0.05)

    # Title line 1
    title1 = config["title"]
    bbox1 = draw.textbbox((0, 0), title1, font=title_font)
    t1_w = bbox1[2] - bbox1[0]
    draw_text_with_shadow(
        draw, ((OUT_W - t1_w) // 2, text_y),
        title1, title_font, fill=(255, 255, 255, 255),
        shadow_offset=5, shadow_alpha=40,
    )

    # Title line 2
    title2 = config["title2"]
    bbox2 = draw.textbbox((0, 0), title2, font=title_font)
    t2_w = bbox2[2] - bbox2[0]
    draw_text_with_shadow(
        draw, ((OUT_W - t2_w) // 2, text_y + 145),
        title2, title_font, fill=(255, 255, 255, 255),
        shadow_offset=5, shadow_alpha=40,
    )

    # Subtitle
    sub_y = text_y + 300
    subtitle = config["subtitle"]
    bbox3 = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    s_w = bbox3[2] - bbox3[0]
    draw.text(
        ((OUT_W - s_w) // 2, sub_y),
        subtitle,
        fill=(255, 255, 255, 200),
        font=subtitle_font,
    )

    # Save
    safe_name = f"screenshot_{index + 1}.png"
    output_path = os.path.join(OUT_DIR, safe_name)
    bg_rgb = bg.convert("RGB")
    bg_rgb.save(output_path, "PNG", quality=100)
    print(f"✅ [{index + 1}] {config['title']}{config['title2']} → {safe_name}")
    return output_path


if __name__ == "__main__":
    print("🎨 Generating App Store screenshots (V2 - Marketing Optimized)...")
    print(f"   Output: {OUT_W} x {OUT_H} | {len(screenshots)} images\n")

    for i, config in enumerate(screenshots):
        generate_screenshot(config, i)

    print(f"\n🎉 All done! Saved to: {OUT_DIR}/")
