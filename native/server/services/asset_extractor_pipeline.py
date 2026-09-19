#!/usr/bin/env python3
"""Asset extraction pipeline - UnityPy-based bundle parser."""
import sys
from pathlib import Path
from typing import List, Dict, Any

# Game paths
GAME_ROOT = Path(r"D:\Program Files\Steam\steamapps\common\StudentAge")
DLC_DIR = GAME_ROOT / "DLC/StandaloneWindows64"


class BundleParser:
    """Parse Unity AssetBundle files using UnityPy."""

    def __init__(self, bundle_path: Path):
        self.bundle_path = bundle_path
        self.assets: List[Dict[str, Any]] = []

    def parse(self) -> List[Dict[str, Any]]:
        """Parse bundle and return list of assets."""
        try:
            import unitypy
            
            app = unitypy.load(path=str(self.bundle_path))
            
            for obj in app.iter():
                asset_info = self._process_object(obj)
                if asset_info:
                    self.assets.append(asset_info)
                    
            return self.assets
            
        except ImportError:
            print("ERROR: UnityPy not installed. Run: pip install unitypy")
            sys.exit(1)
        except Exception as e:
            print(f"ERROR parsing {self.bundle_path}: {e}")
            return []

    def _process_object(self, obj) -> Dict[str, Any] | None:
        """Process a single Unity object and extract metadata."""
        path = obj.path.name
        type_name = obj.type
        
        result = {
            "path": str(obj.path),
            "name": path,
            "type": type_name,
            "size": obj.size if hasattr(obj, 'size') else 0,
        }
        
        # Extract based on type
        if type_name == "Texture2D":
            result.update({
                "width": obj.source.get("m_Width", 0),
                "height": obj.source.get("m_Height", 0),
                "format": obj.source.get("m_Format", ""),
            })
            
        elif type_name == "AudioClip":
            result.update({
                "length": obj.source.get("m_Length", 0),
                "frequency": obj.source.get("m_AudioFormat", 0),
            })
            
        elif type_name == "TextAsset":
            content = obj.read()
            if isinstance(content, bytes):
                try:
                    text_content = content.decode("utf-8")
                    result["is_json"] = text_content.strip().startswith(("{", "["))
                    result["preview"] = text_content[:200] + "..." if len(text_content) > 200 else text_content
                except:
                    result["is_binary"] = True
                    
        elif type_name == "Sprite":
            result.update({
                "rect_x": obj.source.get("m_Rect", {}).get("x", 0),
                "rect_y": obj.source.get("m_Rect", {}).get("y", 0),
                "border": obj.source.get("m_Border", [0, 0, 0, 0]),
            })
            
        return result if result["size"] > 0 else None


def scan_dlc_bundles() -> List[Path]:
    """Scan DLC directory for all bundle files."""
    if not DLC_DIR.exists():
        print(f"ERROR: DLC directory not found at {DLC_DIR}")
        return []
        
    bundle_files = sorted(DLC_DIR.glob("*.bundle"))
    print(f"Found {len(bundle_files)} bundle files in {DLC_DIR}")
    
    for bf in bundle_files:
        size_mb = bf.stat().st_size / (1024 * 1024)
        print(f"  - {bf.name} ({size_mb:.2f} MB)")
        
    return bundle_files


def main():
    """Main entry point for testing."""
    print("=" * 60)
    print("UnityPy AssetBundle Scanner")
    print("=" * 60)
    
    bundle_files = scan_dlc_bundles()
    
    if not bundle_files:
        print("\nNo bundles found to scan.")
        return
        
    # Parse first bundle as test
    test_bundle = bundle_files[0]
    print(f"\nParsing {test_bundle.name}...")
    
    parser = BundleParser(test_bundle)
    assets = parser.parse()
    
    print(f"\nParsed {len(assets)} assets from {test_bundle.name}:")
    for asset in assets[:10]:  # Show first 10
        print(f"  - {asset['name']} ({asset['type']})")
        
    print("\n... see full list below:")
    for asset in assets:
        print(f"  • {asset['path']} → {asset['type']}")


if __name__ == "__main__":
    main()
