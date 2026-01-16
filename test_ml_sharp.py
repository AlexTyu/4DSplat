#!/usr/bin/env python3
"""Test ml-sharp installation and functionality"""
import sys
import os
from pathlib import Path

# Add ml-sharp to path
project_root = Path(__file__).parent
ml_sharp_src = project_root / "ml-sharp" / "src"
sys.path.insert(0, str(ml_sharp_src))

print(f"Project root: {project_root}")
print(f"ml-sharp src: {ml_sharp_src}")
print(f"ml-sharp exists: {ml_sharp_src.exists()}")

try:
    print("\n1. Testing sharp.cli import...")
    from sharp.cli import main_cli
    print("   ✓ sharp.cli imported successfully")
    
    print("\n2. Testing sharp.cli.predict import...")
    from sharp.cli.predict import predict_cli
    print("   ✓ sharp.cli.predict imported successfully")
    
    print("\n3. Testing with test image...")
    test_image = project_root / "test.jpg"
    test_input_dir = project_root / "test_input"
    test_output_dir = project_root / "test_output"
    
    print(f"   Test image exists: {test_image.exists()}")
    
    # Create input directory
    test_input_dir.mkdir(exist_ok=True)
    if test_image.exists():
        import shutil
        shutil.copy2(test_image, test_input_dir / "test.jpg")
        print(f"   Copied test image to {test_input_dir}")
    
    # Set up environment
    os.environ['PYTHONPATH'] = str(ml_sharp_src)
    
    print(f"\n4. Running sharp predict...")
    print(f"   Input: {test_input_dir}")
    print(f"   Output: {test_output_dir}")
    
    # Import and run
    import subprocess
    result = subprocess.run(
        [sys.executable, "-m", "sharp.cli", "predict", 
         "-i", str(test_input_dir), 
         "-o", str(test_output_dir),
         "--device", "cpu"],
        capture_output=True,
        text=True,
        cwd=str(project_root)
    )
    
    print(f"\n5. Command output:")
    print(f"   Return code: {result.returncode}")
    if result.stdout:
        print(f"   stdout:\n{result.stdout[:500]}")
    if result.stderr:
        print(f"   stderr:\n{result.stderr[:500]}")
    
    # Check output
    if test_output_dir.exists():
        ply_files = list(test_output_dir.glob("*.ply"))
        print(f"\n6. Results:")
        print(f"   Output directory exists: {test_output_dir.exists()}")
        print(f"   PLY files created: {len(ply_files)}")
        for ply_file in ply_files[:5]:
            print(f"     - {ply_file.name} ({ply_file.stat().st_size} bytes)")
    else:
        print(f"\n6. Output directory was not created")
    
    print("\n✓ Test completed!")
    
except Exception as e:
    print(f"\n✗ Error: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
