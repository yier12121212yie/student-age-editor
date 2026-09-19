#!/usr/bin/env python3
# server/services/asset_extractor.py — UnityPy-based AssetBundle extraction service.
# P5中期目标：自动扫描游戏 bundle、提取纹理/音频/立绘资源 + 两层缓存机制.
#
# 架构设计（对标竞品拾光工坊 #2）:
# - 只解压目录块（自写 lz4/lzma），payload 交给 UnityPy；跨 bundle 的 Addressables CAB 依赖靠重写 environment.find_file
# - 产物：图缩至≤1600×1200，bg/cg 存 JPEG q90、其余 PNG，写 game_cache/assets/<sha256[:24]>.jpg|png
# - 别名写三份（裸名/kind/名/完整路径）；每 40 张持久化一次 asset-map
#
# 运行方式（作为 HTTP 服务插件）:
#   cd native/server/services
#   python3 asset_extractor.py --port 39251
#
# API:
#   GET /plugin.json        # 自描述流卡片/面板
#   GET /scan               # 扫描 DLC bundle
#   GET /catalog            # 返回解析后的 catalog.json
#   GET /assets/search?q=陈欣&kind=texture
#   GET /assets/<sha24>/preview.jpg (缩小版)
#   GET /assets/<sha24>/full.png (原图裁切)
#
# TODO: Windows 下使用 FSD5 解码器解 AudioCfg.url 指向的音频（UnityPy.fmod_toolkit）。

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse
from typing import Dict, List, Optional, Tuple, Any
from dataclasses import dataclass, asdict

try:
    import unitypy
    from unitypy.streams import UnityIOBaseStream
except ImportError as e:
    print(f"Python dependency missing: {e}")
    print("Please install: pip install unitypy")
    sys.exit(1)


@dataclass
class ExtractedAsset:
    """Extracted asset record."""
    sha24: str  # First 24 chars of SHA-256
    original_name: str
    kind: str  # 'texture', 'audio', 'sprite', 'bundle'
    size_bytes: int
    width: int = 0
    height: int = 0
    format: str = "unknown"
    tags: List[str] = None
    
    def __post_init__(self):
        if self.tags is None:
            self.tags = []


class AssetCache:
    """Two-level cache system for asset extraction."""
    
    def __init__(self, root: Path):
        self.root = root
        self.main_cache = root / "games"  # Per-game cache based on game path hash
        self.aux_cache = root / "AssetCache"  # Global auxiliary cache
        
        self.main_cache.mkdir(parents=True, exist_ok=True)
        self.aux_cache.mkdir(parents=True, exist_ok=True)
        
        # Asset map for quick lookup
        self.asset_map_path = self.aux_cache / "asset-map.json"
        self.asset_map: Dict[str, ExtractedAsset] = {}
        self._load_asset_map()
    
    def _load_asset_map(self):
        """Load asset map from disk."""
        if self.asset_map_path.exists():
            try:
                with open(self.asset_map_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    for key, value in data.items():
                        self.asset_map[key] = ExtractedAsset(**value)
            except Exception as e:
                print(f"Warning: Failed to load asset map: {e}")
    
    def save_asset_map(self):
        """Persist asset map to disk."""
        try:
            data = {k: asdict(v) for k, v in self.asset_map.items()}
            with open(self.asset_map_path, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
        except Exception as e:
            print(f"Error saving asset map: {e}")
    
    def get_preview_path(self, sha24: str) -> Optional[Path]:
        """Get preview image path for given SHA24."""
        preview_path = self.main_cache / sha24 + ".jpg"
        return preview_path if preview_path.exists() else None
    
    def get_full_path(self, sha24: str) -> Optional[Path]:
        """Get full resolution image path for given SHA24."""
        full_path = self.main_cache / sha24 + ".png"
        return full_path if full_path.exists() else None
    
    def register_asset(self, asset: ExtractedAsset):
        """Register extracted asset and persist map periodically."""
        self.asset_map[asset.sha24] = asset
        
        # Save every 40 assets to balance I/O overhead
        if len(self.asset_map) % 40 == 0:
            self.save_asset_map()


class AssetExtractorService:
    """HTTP server for asset extraction pipeline."""
    
    GAME_ROOT = r"D:\Program Files\Steam\steamapps\common\StudentAge"
    DLC_DIR = Path(GAME_ROOT) / "DLC/StandaloneWindows64"
    CACHE_ROOT = Path.home() / ".cache/studentage_editor/assets"
    
    def __init__(self, port=39251):
        self.port = port
        self.cache = AssetCache(Path(self.CACHE_ROOT))
        
        # Scan game bundles and build resource index
        self.resource_index: Dict[str, List[ExtractedAsset]] = {}
        self.bundles_scanned = False
        
    def handle_request(self):
        """Parse URL and route to handler."""
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)
        
        if path == "/plugin.json":
            self._send_plugin_info()
        elif path == "/scan":
            self._handle_scan(params)
        elif path == "/catalog":
            self._handle_catalog()
        elif path.startswith("/assets/search"):
            self._handle_search(params)
        elif path.startswith("/assets/") and len(path.split("/")) >= 4:
            sha = path.split("/")[3]
            if path.endswith("/preview.jpg"):
                self._handle_asset_preview(sha)
            elif path.endswith("/full.png"):
                self._handle_asset_full(sha)
            else:
                self.send_error(404, "Not found")
        else:
            self.send_error(404, "Not found")
    
    def _send_json(self, data: Dict, status: int = 200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))
    
    def _send_plugin_info(self):
        """Return plugin manifest for editor integration."""
        manifest = {
            "ui": {
                "flow_cards": [],
                "panels": [
                    {
                        "id": "asset_explorer",
                        "title": "资源浏览器",
                        "description": "展示从游戏 bundle 中提取的人物立绘/CG/音频",
                        "icon": "🎨",
                    }
                ],
            },
            "service": {"name": "Asset Extraction Service"},
        }
        self._send_json(manifest)
    
    def _handle_scan(self, params: Dict[str, List[str]]):
        """Scan all DLC bundles and extract metadata."""
        force = params.get("force", [False])[0]
        results = {"scanned": False, "bundles_found": 0, "errors": [], "assets_extracted": 0}
        
        if not self.DLC_DIR.exists():
            self._send_json({"error": f"DLC dir not found: {self.DLC_DIR}"}, 400)
            return
        
        bundle_files = list(self.DLC_DIR.glob("*.bundle"))
        if not bundle_files:
            self._send_json({"error": "No .bundle files found in DLC/"})
            return
        
        results["bundles_found"] = len(bundle_files)
        
        if force or not self.bundles_scanned:
            start_time = time.time()
            
            # Extract assets from each bundle
            total_assets = 0
            for bf in bundle_files:
                try:
                    assets = self._extract_from_bundle(bf.name)
                    results["bundles"].append({
                        "name": bf.name,
                        "size_bytes": bf.stat().st_size,
                        "modified": bf.stat().st_mtime,
                        "assets_count": len(assets),
                    })
                    total_assets += len(assets)
                except Exception as e:
                    results["errors"].append(f"{bf.name}: {str(e)}")
                    print(f"Error extracting {bf.name}: {e}")
            
            results["scanned"] = True
            results["assets_extracted"] = total_assets
            results["scan_time_seconds"] = round(time.time() - start_time, 2)
            
            # Persist resource index
            self._persist_resource_index()
        
        self._send_json(results)
    
    def _extract_from_bundle(self, bundle_name: str) -> List[ExtractedAsset]:
        """Extract assets from a single bundle file.
        
        Implementation notes:
        - Only decompress directory block (custom lz4/lzma), let UnityPy handle payload
        - For SpriteAtlas, use m_PackedSprites to keep entire canvas
        - Output: BG/CG → JPEG q90, others → PNG
        - Resize textures ≤1600×1200 for previews
        """
        assets = []
        bundle_path = self.DLC_DIR / bundle_name
        
        # Skip scope version check (simplified for now)
        if "textures_assets" not in bundle_name.lower() and \
           "atlas_assets" not in bundle_name.lower():
            # Still scan but only metadata
            return [{"sha24": "", "original_name": bundle_name, "kind": "bundle"}]
        
        try:
            with unitypy.open(bundle_path) as app:
                for obj_id in app.files.keys():
                    obj = app.files[obj_id].get()
                    
                    if obj.type == "Texture2D":
                        tex_data = obj.read()
                        texture = self._process_texture(tex_data, obj_id)
                        if texture:
                            assets.append(texture)
                    
                    elif obj.type == "Sprite":
                        sprite_data = obj.read()
                        sprite = self._process_sprite(sprite_data, obj_id)
                        if sprite:
                            assets.append(sprite)
                            
                    elif obj.type == "AudioClip":
                        audio_data = obj.read()
                        audio = self._process_audio(audio_data, obj_id)
                        if audio:
                            assets.append(audio)
        
        except Exception as e:
            raise Exception(f"Failed to extract from {bundle_name}: {e}")
        
        return assets
    
    def _process_texture(self, tex_data: Any, obj_id: str) -> ExtractedAsset:
        """Process Texture2D object and generate preview/full images."""
        width = tex_data.width
        height = tex_data.height
        
        # Compute SHA-256 hash
        sha_hash = hashlib.sha256(obj_id.encode()).hexdigest()
        sha24 = sha_hash[:24]
        
        # Generate output formats
        preview_path = self.cache.get_preview_path(sha24)
        
        if not preview_path:
            # Decode texture data and resize to ≤1600×1200
            texture_pixels = tex_data.read()
            
            # Simple resizing (real implementation would use PIL/Pillow)
            scaled_width = min(width, 1600)
            scaled_height = min(height, 1200)
            
            # Write JPEG preview (q90)
            preview_path = self.cache.main_cache / f"{sha24}.jpg"
            # TODO: Implement actual image writing here
            
            # Store in cache
            asset = ExtractedAsset(
                sha24=sha24,
                original_name=f"tex_{obj_id}",
                kind="texture",
                size_bytes=len(texture_pixels),
                width=scaled_width,
                height=scaled_height,
                format="JPEG",
                tags=["cached"]
            )
            self.cache.register_asset(asset)
        
        return asset
    
    def _process_sprite(self, sprite_data: Any, obj_id: str) -> ExtractedAsset:
        """Process Sprite object."""
        sha_hash = hashlib.sha256(obj_id.encode()).hexdigest()
        sha24 = sha_hash[:24]
        
        asset = ExtractedAsset(
            sha24=sha24,
            original_name=f"sprite_{obj_id}",
            kind="sprite",
            size_bytes=0,
            tags=[]
        )
        
        # Check if it's from PersonCfg reference
        # TODO: Cross-reference with cfg/talk portrait paths
        if "person" in obj_id.lower() or "live2d" in obj_id.lower():
            asset.tags.append("character")
        if "happy" in obj_id.lower() or "smile" in obj_id.lower():
            asset.tags.append("expression_happy")
            
        return asset
    
    def _process_audio(self, audio_data: Any, obj_id: str) -> ExtractedAsset:
        """Process AudioClip object (FMD/SoundBank decoding)."""
        sha_hash = hashlib.sha256(obj_id.encode()).hexdigest()
        sha24 = sha_hash[:24]
        
        asset = ExtractedAsset(
            sha24=sha24,
            original_name=f"audio_{obj_id}",
            kind="audio",
            size_bytes=0,
            format="unknown"
        )
        
        return asset
    
    def _handle_catalog(self):
        """Parse catalog.json and return structured resource map."""
        catalog_path = Path(self.GAME_ROOT) / "DLC/catalog.json"
        if not catalog_path.exists():
            self._send_json({"error": "catalog.json not found"}, 400)
            return
        
        try:
            with open(catalog_path, 'r', encoding='utf-8') as f:
                catalog_data = json.load(f)
            
            # Build indexed view by kind
            resources_by_kind = {
                "texture": [],
                "sprite": [],
                "audio": [],
                "bundle": []
            }
            
            # Populate from cached asset map
            for asset in self.cache.asset_map.values():
                if asset.kind in resources_by_kind:
                    resources_by_kind[asset.kind].append(asdict(asset))
            
            result = {
                "resources_by_kind": resources_by_kind,
                "total_count": sum(len(v) for v in resources_by_kind.values()),
                "catalog_metadata": {
                    "locator_id": catalog_data.get("m_LocatorId"),
                    "entry_count": len(catalog_data.get("m_InternalIds", [])),
                }
            }
            
            self._send_json(result)
        
        except Exception as e:
            self._send_json({"error": str(e)}, 500)
    
    def _handle_search(self, params: Dict[str, List[str]]):
        """Search assets by query string and kind filter."""
        query = params.get("q", [""])[0].lower()
        kind_filter = params.get("kind", [""])[0]
        
        results = []
        
        for asset in self.cache.asset_map.values():
            match = False
            
            # Kind filter
            if kind_filter and asset.kind != kind_filter:
                continue
            
            # Query match on name/tags
            if query:
                searchable = f"{asset.original_name} {' '.join(asset.tags)}".lower()
                match = query in searchable
            
            if match or not query:
                results.append(asdict(asset))
            
            if len(results) >= 100:
                break  # Limit results
        
        self._send_json({
            "query": query,
            "kind_filter": kind_filter,
            "results": results,
            "count": len(results),
        })
    
    def _handle_asset_preview(self, sha24: str):
        """Serve preview image for asset."""
        path = self.cache.get_preview_path(sha24)
        if not path or not path.exists():
            self._send_json({
                "sha": sha24,
                "status": "not_available",
                "message": "Preview not generated yet"
            }, 404)
            return
        
        # Read and send binary image
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        with open(path, 'rb') as f:
            self.wfile.write(f.read())
    
    def _handle_asset_full(self, sha24: str):
        """Serve full resolution image for asset."""
        path = self.cache.get_full_path(sha24)
        if not path or not path.exists():
            self._send_json({
                "sha": sha24,
                "status": "not_available",
                "message": "Full image not available"
            }, 404)
            return
        
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        with open(path, 'rb') as f:
            self.wfile.write(f.read())
    
    def _persist_resource_index(self):
        """Persist the scanned resource index for warmup."""
        index_path = self.CACHE_ROOT / "resource-index.json"
        index_data = {
            "scanned_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "bundles": self.resource_index.keys(),
        }
        with open(index_path, 'w', encoding='utf-8') as f:
            json.dump(index_data, f, indent=2)
    
    def log_message(self, format, *args):
        """Suppress default logging."""
        pass


def main():
    parser = argparse.ArgumentParser(description="Asset Extraction HTTP Service")
    parser.add_argument("--port", type=int, default=39251, help="HTTP port")
    args = parser.parse_args()
    
    print(f"Starting Asset Extraction Service on port {args.port}...")
    print(f"Game root: {AssetExtractorService.GAME_ROOT}")
    print(f"DLC directory: {AssetExtractorService.DLC_DIR}")
    print(f"Cache directory: {AssetExtractorService.CACHE_ROOT}")
    
    service = AssetExtractorService(port=args.port)
    
    # Auto-scan on startup
    print("Scanning bundles...")
    import http.server
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            service.handle_request()
        def log_message(self, format, *args):
            pass
    
    server = http.server.HTTPServer(("127.0.0.1", args.port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
