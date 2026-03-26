#!/usr/bin/env python3
"""Generate App Store promotional screenshots for SplitCam"""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

# Output size: 1290 x 2796 (6.7" iPhone)
OUT_W, OUT_H = 1290, 2796

# Screenshot configs
screenshots = [
    {
        "file": "IMG_4079.PNG",
        "title_zh": "前后双摄",
        "subtitle_zh": "同时记录两个视角",
        "title_en": "Dual Camera",
        "subtitle_en": "Capture both sides at once",
        "gradient": [(30, 50, 120), (80, 40, 140)],  # deep blue to purple
    },
    {
        "file": "IMG_4086.PNG",
        "title_zh": "画中画模式",
        "subtitle_zh": "自由拖拽 随意缩放",
        "title_en": "Picture in Picture",
        "subtitle_en": "Drag & resize freely",
        "gradient": [(40, 20, 100), (120, 40, 160)],  # indigo to violet
    },
    {
        "file": "IMG_4089.PNG",
        "title_zh": "多种布局",
        "subtitle_zh": "上下分屏 多比例切换",
        "title_en": "Multiple Layouts",
        "subtitle_en": "Top-bottom split & aspect ratios",
        "gradient": [(20, 60, 100), (40, 120, 140)],  # dark teal to teal
    },
    {
        "file": "IMG_4093.PNG",
        "title_zh": "合拍模式",
        "subtitle_zh": "导入视频 同框录制",
        "title_en": "Duet Mode",
        "subtitle_en": "Import video & record together",
        "gradient": [(80, 30, 80), (140, 50, 100)],  # purple to magenta
    },
]

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(BASE_DIR, "appstore_screenshots")
os.makedirs(OUT_DIR, exist_ok=True)


def create_gradient(size, color_top, color_bottom):
    """Create a vertical gradient image"""
    img = Image.new("RGB", size)
    draw = ImageDraw.Draw(img)
    for y in range(size[1]):
        ratio = y / size[1]
        r = int(color_top[0] + (color_bottom[0] - color_top[0]) * ratio)
        g = int(color_top[1] + (color_bottom[1] - color_top[1]) * ratio)
        b = int(color_top[2] + (color_bottom[2] - color_top[2]) * ratio)
        draw.line([(0, y), (size[0], y)], fill=(r, g, b))
    return img


def get_font(size, bold=False):
    """Try to get a good font, fallback gracefully"""
    font_paths = [
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Supplemental/PingFang.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for fp in font_paths:
        if os.path.exists(fp):
            try:
                # For .ttc files, index 0 is regular, higher indices may be bold
                idx = 1 if bold else 0
                return ImageFont.truetype(fp, size, index=idx)
            except Exception:
                try:
                    return ImageFont.truetype(fp, size)
                except Exception:
                    continue
    return ImageFont.load_default()


def add_phone_frame(screenshot, target_w, target_h, corner_radius=40):
    """Resize screenshot and add rounded corners"""
    # Resize to fit
    img = screenshot.copy()
    img = img.resize((target_w, target_h), Image.LANCZOS)

    # Create rounded corner mask
    mask = Image.new("L", (target_w, target_h), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        [(0, 0), (target_w - 1, target_h - 1)],
        radius=corner_radius,
        fill=255,
    )

    # Apply mask
    output = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    img_rgba = img.convert("RGBA")
    output.paste(img_rgba, (0, 0), mask)

    # Add subtle border
    border_draw = ImageDraw.Draw(output)
    border_draw.rounded_rectangle(
        [(0, 0), (target_w - 1, target_h - 1)],
        radius=corner_radius,
        outline=(255, 255, 255, 80),
        width=3,
    )

    return output


def generate_screenshot(config, index):
    """Generate one promotional screenshot"""
    # Create gradient background
    bg = create_gradient((OUT_W, OUT_H), config["gradient"][0], config["gradient"][1])
    bg = bg.convert("RGBA")

    # Load screenshot
    img_path = os.path.join(BASE_DIR, config["file"])
    screenshot = Image.open(img_path)

    # Calculate phone frame size (about 75% width, positioned lower)
    phone_w = int(OUT_W * 0.72)
    phone_h = int(phone_w * screenshot.height / screenshot.width)

    # Cap height
    max_phone_h = int(OUT_H * 0.68)
    if phone_h > max_phone_h:
        phone_h = max_phone_h
        phone_w = int(phone_h * screenshot.width / screenshot.height)

    # Add rounded corners to screenshot
    phone_img = add_phone_frame(screenshot, phone_w, phone_h, corner_radius=36)

    # Add shadow behind phone
    shadow = Image.new("RGBA", (phone_w + 40, phone_h + 40), (0, 0, 0, 0))
    shadow_base = Image.new("RGBA", (phone_w, phone_h), (0, 0, 0, 100))
    shadow.paste(shadow_base, (20, 20))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=20))

    # Position phone (centered horizontally, lower portion)
    phone_x = (OUT_W - phone_w) // 2
    phone_y = OUT_H - phone_h - int(OUT_H * 0.06)

    # Paste shadow then phone
    bg.paste(shadow, (phone_x - 20, phone_y - 10), shadow)
    bg.paste(phone_img, (phone_x, phone_y), phone_img)

    # Draw text
    draw = ImageDraw.Draw(bg)

    # Title (large, bold)
    title_font = get_font(108, bold=True)
    subtitle_font = get_font(52, bold=False)
    en_font = get_font(42, bold=False)

    # Calculate text position (top area)
    text_y_start = int(OUT_H * 0.06)

    # Chinese title
    title = config["title_zh"]
    bbox = draw.textbbox((0, 0), title, font=title_font)
    title_w = bbox[2] - bbox[0]
    draw.text(
        ((OUT_W - title_w) // 2, text_y_start),
        title,
        fill=(255, 255, 255, 255),
        font=title_font,
    )

    # Chinese subtitle
    subtitle = config["subtitle_zh"]
    bbox2 = draw.textbbox((0, 0), subtitle, font=subtitle_font)
    sub_w = bbox2[2] - bbox2[0]
    draw.text(
        ((OUT_W - sub_w) // 2, text_y_start + 140),
        subtitle,
        fill=(255, 255, 255, 200),
        font=subtitle_font,
    )

    # English subtitle (smaller)
    en_text = config["subtitle_en"]
    bbox3 = draw.textbbox((0, 0), en_text, font=en_font)
    en_w = bbox3[2] - bbox3[0]
    draw.text(
        ((OUT_W - en_w) // 2, text_y_start + 210),
        en_text,
        fill=(255, 255, 255, 140),
        font=en_font,
    )

    # Save
    output_path = os.path.join(OUT_DIR, f"screenshot_{index + 1}_{config['title_en'].replace(' ', '_').lower()}.png")
    bg_rgb = bg.convert("RGB")
    bg_rgb.save(output_path, "PNG", quality=100)
    print(f"✅ Generated: {output_path}")
    return output_path


if __name__ == "__main__":
    print("🎨 Generating App Store screenshots...")
    print(f"   Output size: {OUT_W} x {OUT_H}")
    print()

    for i, config in enumerate(screenshots):
        generate_screenshot(config, i)

    print(f"\n🎉 Done! {len(screenshots)} screenshots saved to: {OUT_DIR}/")
