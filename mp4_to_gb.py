#!/usr/bin/env python3
"""
MP4 to Game Boy ROM Converter
Wrapper script for shysaur's dmg-badapple-av project
Converts MP4 videos into playable Game Boy ROMs
"""

import os
import sys
import subprocess
import argparse
import shutil
import re
from pathlib import Path

class GameBoyVideoConverter:
    def __init__(self, repo_path):
        self.repo_path = Path(repo_path).resolve()
        self.frames_dir = self.repo_path / "frames"
        self.frames2data = self.repo_path / "frames2data.py"
        self.wav2data = self.repo_path / "wav2data.py"
        self.makefile = self.repo_path / "Makefile"
        self.video_asm = self.repo_path / "src" / "video.asm"

    def patch_rgbds_syntax(self):
        """Auto-patch video.asm for newer RGBDS versions"""
        if not self.video_asm.exists():
            print(f"⚠️  Warning: {self.video_asm} not found, skipping patch")
            return True

        print("🔧 Checking RGBDS syntax compatibility...")

        # Check if already patched
        with open(self.video_asm, 'r') as f:
            content = f.read()

        # If already has DEF before first EQU, assume it's already patched
        if re.search(r'DEF PULLDOWN_SKIPF EQU', content):
            print("   ✅ Already patched")
            return True

        print("   🔧 Patching for newer RGBDS...")

        # Create backup if doesn't exist
        backup = self.video_asm.with_suffix('.asm.bak')
        if not backup.exists():
            shutil.copy(self.video_asm, backup)
            print(f"   📋 Created backup: {backup.name}")

        lines = content.split('\n')
        fixed_lines = []

        for line in lines:
            # Skip if already has DEF, is a comment, or is empty
            if (line.strip().startswith(';') or
                'DEF ' in line or
                not line.strip() or
                'INCLUDE' in line or
                'SECTION' in line or
                'EXPORT' in line):
                fixed_lines.append(line)
                continue

            # Check if line has EQU without DEF at the start
            # Match: optional whitespace, symbol name, whitespace, EQU
            match = re.match(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s+EQU\s+.*)$', line)
            if match:
                indent, symbol, rest = match.groups()
                fixed_line = f"{indent}DEF {symbol}{rest}"
                fixed_lines.append(fixed_line)
                continue

            fixed_lines.append(line)

        # Write back
        with open(self.video_asm, 'w') as f:
            f.write('\n'.join(fixed_lines))

        print("   ✅ Syntax patched successfully")
        return True

    def check_dependencies(self):
        """Check if required tools are installed"""
        deps = {
            'ffmpeg': 'FFmpeg (for video/audio processing)',
            'python3': 'Python 3',
            'rgbasm': 'RGBDS (Game Boy assembler)',
            'rgblink': 'RGBDS linker',
            'rgbfix': 'RGBDS ROM fixer'
        }

        missing = []
        for cmd, desc in deps.items():
            if not shutil.which(cmd):
                missing.append(f"  - {desc} ({cmd})")

        if missing:
            print("❌ Error: Missing required dependencies:")
            print('\n'.join(missing))
            print("\nInstall RGBDS from: https://rgbds.gbdev.io/")
            return False

        # Check Python libraries
        try:
            import PIL
        except ImportError:
            print("❌ Error: Missing Python library 'Pillow'")
            print("   Install with: pip install Pillow")
            return False

        try:
            import soundfile
        except ImportError:
            print("❌ Error: Missing Python library 'soundfile'")
            print("   Install with: pip install soundfile")
            return False

        return True

    def extract_frames(self, video_path, config=0, pulldown=1.0):
        """Extract frames from video using ffmpeg"""
        print(f"\n[1/5] 🎬 Extracting frames from video...")

        # Determine resolution based on config
        configs = {
            0: (160, 72),   # 20x9 tiles
            1: (160, 64),   # 20x8 tiles
            2: (160, 56)    # 20x7 tiles (less tested)
        }
        width, height = configs.get(config, (160, 72))

        # Clean and create frames directory
        if self.frames_dir.exists():
            shutil.rmtree(self.frames_dir)
        self.frames_dir.mkdir(parents=True)

        # Calculate FPS based on pulldown (30 fps base, adjusted by pulldown)
        fps = 30 / pulldown

        # Extract frames as BMP (the script expects BMP by default)
        # Convert to grayscale and apply threshold for black & white
        cmd = [
            'ffmpeg',
            '-i', str(video_path),
            '-vf', f'fps={fps},scale={width}:{height}:flags=lanczos,format=gray',
            '-pix_fmt', 'gray',
            str(self.frames_dir / '%d.bmp')
        ]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"❌ Error extracting frames: {result.stderr}")
            return False

        frame_count = len(list(self.frames_dir.glob('*.bmp')))
        print(f"   ✅ Extracted {frame_count} frames at {width}x{height} ({fps:.1f} fps)")
        return True

    def extract_audio(self, video_path, output_wav):
        """Extract audio from video as WAV (stereo, 44100 Hz)"""
        print(f"\n[2/5] 🎵 Extracting audio...")

        cmd = [
            'ffmpeg',
            '-i', str(video_path),
            '-vn',                  # No video
            '-acodec', 'pcm_s16le', # 16-bit PCM
            '-ar', '44100',         # 44.1 kHz sample rate (required)
            '-ac', '2',             # Stereo (required)
            '-y',                   # Overwrite
            str(output_wav)
        ]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"⚠️  Warning: Audio extraction failed: {result.stderr}")
            return False

        print(f"   ✅ Audio extracted")
        return True

    def build_rom(self, output_rom, config=0, pulldown=1.0, sound_path=None):
        """Build the final ROM using make"""
        print("\n[5/5] 🔨 Building Game Boy ROM...")

        if not self.makefile.exists():
            print(f"❌ Error: Makefile not found at {self.makefile}")
            return False

        # Prepare make command with parameters
        make_cmd = [
            'make',
            f'CONFIG={config}',
            f'PULLDOWN={pulldown}',
            'FRAMEEXT=bmp'
        ]

        # Add sound file if provided
        if sound_path and Path(sound_path).exists():
            make_cmd.append(f'SOUND={sound_path}')

        # Run make
        result = subprocess.run(
            make_cmd,
            cwd=str(self.repo_path),
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            print(f"❌ Error building ROM:")
            print(result.stderr)
            if result.stdout:
                print(result.stdout)
            return False

        # The ROM is built as video.gb by default
        built_rom = self.repo_path / 'video.gb'
        if not built_rom.exists():
            print("❌ Error: video.gb not found after build")
            return False

        # Copy to output location
        shutil.copy(built_rom, output_rom)

        file_size = os.path.getsize(output_rom) / (1024 * 1024)
        print(f"   ✅ ROM built successfully: {output_rom} ({file_size:.2f} MB)")
        return True

def main():
    parser = argparse.ArgumentParser(
        description='Convert MP4 video to Game Boy ROM using dmg-badapple-av',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s myvideo.mp4 output.gb
  %(prog)s input.mp4 output.gb --config 1 --fps-multiplier 0.5
  %(prog)s input.mp4 output.gb --no-audio

Resolution options (--config):
  0 = 160x72 pixels (default, best quality)
  1 = 160x64 pixels (slightly smaller ROM)
  2 = 160x56 pixels (smallest ROM, less tested)

FPS multiplier (--fps-multiplier):
  1.0 = 30 fps (default)
  0.5 = 15 fps (half speed, smaller ROM)
  2.0 = 60 fps (double speed, larger ROM)

Notes:
  - Video will be automatically converted to black & white
  - Higher FPS = larger ROM size
  - Typical ROM sizes: 2-8 MB depending on video length
  - Test in an emulator before using on real hardware
        '''
    )

    parser.add_argument('input', help='Input MP4 video file')
    parser.add_argument('output', help='Output .gb ROM file')
    parser.add_argument('--repo', default='.',
                       help='Path to dmg-badapple-av repository (default: current directory)')
    parser.add_argument('--config', type=int, choices=[0, 1, 2], default=0,
                       help='Video config: 0=160x72 (default), 1=160x64, 2=160x56')
    parser.add_argument('--fps-multiplier', type=float, default=1.0,
                       help='FPS multiplier (1.0 = 30fps, 0.5 = 15fps, etc.)')
    parser.add_argument('--no-audio', action='store_true',
                       help='Skip audio processing (video only)')
    parser.add_argument('--skip-patch', action='store_true',
                       help='Skip RGBDS syntax auto-patching')

    args = parser.parse_args()

    # Validate inputs
    if not os.path.exists(args.input):
        print(f"❌ Error: Input file '{args.input}' not found")
        sys.exit(1)

    # Initialize converter
    converter = GameBoyVideoConverter(args.repo)

    # Display configuration
    configs = {0: "160x72", 1: "160x64", 2: "160x56"}
    target_fps = 30 / args.fps_multiplier

    print("=" * 70)
    print("🎮 MP4 to Game Boy ROM Converter")
    print("=" * 70)
    print(f"Input:       {args.input}")
    print(f"Output:      {args.output}")
    print(f"Resolution:  {configs[args.config]} (config {args.config})")
    print(f"Target FPS:  {target_fps:.1f} fps (pulldown {args.fps_multiplier})")
    print(f"Audio:       {'Disabled' if args.no_audio else 'Enabled'}")
    print("=" * 70)

    # Check dependencies
    print("\n[0/5] 🔍 Checking dependencies...")
    if not converter.check_dependencies():
        sys.exit(1)
    print("   ✅ All dependencies found")

    # Auto-patch RGBDS syntax if needed
    if not args.skip_patch:
        if not converter.patch_rgbds_syntax():
            print("⚠️  Warning: Patching failed, continuing anyway...")

    # Temporary files
    temp_wav = converter.repo_path / 'sound.wav'

    try:
        # Extract frames
        if not converter.extract_frames(args.input, args.config, args.fps_multiplier):
            sys.exit(1)

        # Extract audio (if enabled)
        audio_success = False
        if not args.no_audio:
            audio_success = converter.extract_audio(args.input, temp_wav)
            if not audio_success:
                print("⚠️  Continuing without audio...")

        print("\n[3/5] 🔄 Converting frames to Game Boy format...")
        print("   (This may take a while...)")

        print("\n[4/5] 🎼 Converting audio to Game Boy format...")
        print("   (Processing audio data...)")

        # Build ROM (make will call frames2data.py and wav2data.py)
        sound_file = temp_wav if (not args.no_audio and audio_success) else None
        if not converter.build_rom(args.output, args.config, args.fps_multiplier, sound_file):
            sys.exit(1)

        print("\n" + "=" * 70)
        print("✅ SUCCESS! Game Boy ROM created!")
        print("=" * 70)
        print(f"\n📁 Output: {args.output}")
        print("\n🎮 Next steps:")
        print("  1. Test in an emulator (BGB, SameBoy, mGBA)")
        print("  2. Load onto a flashcart for real hardware")
        print("\n💡 Tips:")
        print("  - If ROM is too large, try --fps-multiplier 0.5 for 15fps")
        print("  - If ROM is too large, try --config 1 or --config 2")
        print("  - Use --no-audio to reduce ROM size significantly")
        print()

    except KeyboardInterrupt:
        print("\n\n⚠️  Conversion cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    finally:
        # Cleanup (optional - the makefile handles most cleanup)
        pass

if __name__ == '__main__':
    main()
