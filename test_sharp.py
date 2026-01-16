#!/usr/bin/env python3
import sys
import os

# Add ml-sharp to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'ml-sharp', 'src'))

try:
    from sharp.cli import main_cli
    print("✓ sharp.cli imported successfully")
    
    # Test if we can access predict command
    import sharp.cli.predict as predict_module
    print("✓ sharp.cli.predict module accessible")
    
    print("\nml-sharp is working! You can use it with:")
    print("  python -m sharp.cli predict -i <input_dir> -o <output_dir>")
    
except Exception as e:
    print(f"✗ Error: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
