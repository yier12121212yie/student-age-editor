#!/usr/bin/env python3
# server/services/live2d_renderer.py — Live2D offline rendering + WebGL streaming service.
# P5 Phase 4: Real-time and offline Live2D preview functionality.
#
# Architecture (competitor #2 benchmark):
# - Offline mode: ctypes wrapper for Live2DCubismCore.dll → PNG cache
# - Online mode: PixiJS WebGL viewer for real-time animation playback
#
# Running as HTTP plugin service:
#   cd native/server/services
#   python3 live2d_renderer.py --port 39252
#
# API:
#   GET /plugin.json          # Self-description for editor integration
#   GET /models               # List all available Live2D models
#   GET /render/<person_id>/<expr_name>  # Render expression, return cached PNG path
#   GET /view/<model_id>       # Return WebGL viewer HTML page
#   POST /animate              # Stream animated frame request for WebGL
#
# TODO: macOS version using Metal renderer (simplified CPU fallback for now)

import argparse
import json
import os
import sys
import time
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse
from typing import Dict, List, Optional, Any
import hashlib


class Live2DRendererService:
    """HTTP server for Live2D rendering and visualization."""
    
    GAME_ROOT = r"D:\Program Files\Steam\steamapps\common\StudentAge"
    L2D_DIR = Path(GAME_ROOT) / "DLC/DLC_L2DModels"
    CACHE_DIR = Path.home() / ".cache/studentage_editor/live2d"
    
    def __init__(self, port=39252):
        self.port = port
        self.model_cache: List[Dict[str, Any]] = []
        self.render_cache: Dict[str, str] = {}
        
        self._load_models()
    
    def _load_models(self):
        """Scan game root for .moc3 files."""
        if not self.L2D_DIR.exists():
            print(f"Warning: Live2D models directory not found: {self.L2D_DIR}")
            self.model_cache = []
            return
        
        models = []
        
        try:
            for subdir in os.listdir(self.L2D_DIR):
                subpath = self.L2D_DIR / subdir
                
                if not subpath.is_dir():
                    continue
                
                # Collect moc3 files and expressions
                moc3_files = [f for f in os.listdir(subpath) if f.endswith('.moc3')]
                
                if moc3_files:
                    model_info = {
                        'id': subdir,
                        'path': str(subpath),
                        'expressions': [],
                        'thumbnail': None,
                    }
                    
                    for moc3 in moc3_files:
                        expr_name = moc3[:-5]  # Remove .moc3 suffix
                        model_info['expressions'].append(expr_name)
                        
                        # Try to render thumbnail
                        thumbnail_path = self._try_render_thumbnail(
                            subpath / moc3, expr_name
                        )
                        if thumbnail_path:
                            model_info['thumbnail'] = thumbnail_path
                    
                    models.append(model_info)
        
        except Exception as e:
            print(f"Error loading Live2D models: {e}")
        
        self.model_cache = models
    
    def _try_render_thumbnail(self, moc3_path: Path, expr_name: str) -> Optional[str]:
        """Try to render expression to cached PNG (offline mode)."""
        cache_key = f"{moc3_path.name}_{expr_name}"
        
        # Check render cache
        if cache_key in self.render_cache:
            return self.render_cache[cache_key]
        
        # Generate SHA-256 based hash for file naming
        sha_hash = hashlib.sha256(str(moc3_path).encode()).hexdigest()[:24]
        cache_path = self.CACHE_DIR / f"{sha_hash}.png"
        
        # Ensure cache directory exists
        self.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        
        # TODO: Implement actual Cubism rendering here
        # For now, just create a placeholder SVG
        if not cache_path.exists():
            placeholder_svg = self._create_placeholder_svg(expr_name)
            with open(cache_path.with_suffix('.svg'), 'w', encoding='utf-8') as f:
                f.write(placeholder_svg)
        
        self.render_cache[cache_key] = str(cache_path)
        return str(cache_path)
    
    def _create_placeholder_svg(self, expr_name: str) -> str:
        """Create placeholder SVG for testing."""
        # Color codes based on expression type
        color_map = {
            'happy': '#00B294',
            'sad': '#F25460',
            'shy': '#7FBA00',
            'angry': '#FFB900',
            'neutral': '#4C72B3',
        }
        
        color = color_map.get(expr_name.lower(), '#CCCCCC')
        
        return f'''<?xml version="1.0" encoding="utf-8"?>
<svg width="512" height="512" xmlns="http://www.w3.org/2000/svg">
  <rect width="512" height="512" fill="{color}"/>
  <text x="256" y="256" text-anchor="middle" dy=".3em" 
        font-size="60" fill="white" font-family="sans-serif">
    {expr_name.upper()}
  </text>
</svg>'''
    
    def handle_request(self):
        """Parse URL and route to handler."""
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)
        
        if path == "/plugin.json":
            self._send_plugin_info()
        elif path == "/models":
            self._handle_list_models()
        elif path.startswith("/render/"):
            self._handle_render(path[8:])  # Remove "/render/" prefix
        elif path.startswith("/view/"):
            self._handle_view(path[6:])  # Remove "/view/" prefix
        elif path == "/view-webgl":
            self._serve_webgl_viewer(params)
        else:
            self.send_error(404, "Not found")
    
    def _send_json(self, data: Dict, status: int = 200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))
    
    def _send_html(self, html_content: str, status: int = 200):
        """Send HTML response."""
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html_content.encode("utf-8"))
    
    def _send_plugin_info(self):
        """Return plugin manifest for editor integration."""
        manifest = {
            "ui": {
                "flow_cards": [],
                "panels": [
                    {
                        "id": "live2d_preview",
                        "title": "Live2D 预览器",
                        "description": "实时预览和离线渲染 Live2D 角色动画",
                        "icon": "🎭",
                    }
                ],
            },
            "service": {"name": "Live2D Renderer Service"},
        }
        self._send_json(manifest)
    
    def _handle_list_models(self):
        """List all available Live2D models."""
        result = {
            "models": self.model_cache,
            "count": len(self.model_cache),
        }
        self._send_json(result)
    
    def _handle_render(self, path_str: str):
        """Render expression and serve cached PNG or SVG."""
        parts = path_str.split("/")
        if len(parts) < 2:
            self.send_error(400, "Missing person_id or expression_name")
            return
        
        person_id = parts[0]
        expr_name = parts[1]
        
        # Find matching model
        model = None
        for m in self.model_cache:
            if m['id'] == person_id or m['path'].endswith(person_id):
                model = m
                break
        
        if not model:
            self.send_error(404, f"Model not found: {person_id}")
            return
        
        # Try to render (or get from cache)
        try:
            thumbnail = self._try_render_thumbnail(
                Path(model['path']) / f"{expr_name}.moc3",
                expr_name
            )
            
            if thumbnail:
                self.send_response(200)
                self.send_header("Content-Type", "image/png" if thumbnail.endswith('.png') else "image/svg+xml")
                self.send_header("Cache-Control", "public, max-age=86400")
                self.end_headers()
                
                with open(thumbnail, 'rb') as f:
                    self.wfile.write(f.read())
            else:
                self.send_error(500, "Failed to generate thumbnail")
        
        except Exception as e:
            self.send_error(500, str(e))
    
    def _handle_view(self, model_id: str):
        """Serve full-page viewer for a model (desktop/embedded mode)."""
        # Find model
        model = None
        for m in self.model_cache:
            if m['id'] == model_id or m['path'].endswith(model_id):
                model = m
                break
        
        if not model:
            self.send_error(404, f"Model not found: {model_id}")
            return
        
        html = self._build_model_viewer_page(model)
        self._send_html(html)
    
    def _build_model_viewer_page(self, model: Dict[str, Any]) -> str:
        """Build standalone viewer page with PixiJS WebGL support."""
        model_path = model['path']
        expressions = model['expressions']
        
        # Default first expression
        default_expr = expressions[0] if expressions else "neutral"
        
        return f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Live2D Viewer - {model['id']}</title>
  <script src="https://cdn.jsdelivr.net/npm/pixi.js@7.2.0/dist/pixi.min.js"></script>
  <style>
    body {{ margin: 0; padding: 20px; background: #1a1a1a; font-family: Segoe UI, sans-serif; }}
    .container {{ display: flex; gap: 20px; height: calc(100vh - 100px); }}
    .viewer {{ flex: 1; display: flex; justify-content: center; align-items: center; }}
    #canvas {{ border: 1px solid #444; background: #2a2a2a; }}
    .controls {{ width: 200px; padding: 10px; background: #2a2a2a; border-radius: 8px; }}
    .controls h3 {{ margin-top: 0; color: #fff; }}
    .controls button {{
      display: block;
      width: 100%;
      padding: 8px;
      margin: 4px 0;
      background: #0078d4;
      color: white;
      border: none;
      border-radius: 4px;
      cursor: pointer;
    }}
    .controls button:hover {{ background: #1078c7; }}
    .controls button.active {{ background: #00b294; }}
    .info {{ margin-bottom: 10px; color: #aaa; font-size: 12px; }}
  </style>
</head>
<body>
  <div class="container">
    <div class="viewer">
      <canvas id="canvas" width="512" height="512"></canvas>
    </div>
    <div class="controls">
      <h3>{model['id']}</h3>
      <div class="info">路径：{model_path}</div>
      <h4>表情切换:</h4>
      {''.join(f'<button data-expr="{expr}">{expr.capitalize()}</button>' for expr in expressions)}
    </div>
  </div>
  
  <script>
    const app = new PIXI.Application({
      width: 512,
      height: 512,
      backgroundColor: 0x2a2a2a
    });
    document.getElementById('canvas').appendChild(app.view);
    
    // Placeholder sprite (would be replaced by real Cubism mesh)
    const placeholder = new PIXI.Sprite(PIXI.Texture.from('/static/placeholder.png'));
    placeholder.anchor.set(0.5);
    placeholder.x = 256;
    placeholder.y = 256;
    app.stage.addChild(placeholder);
    
    // Expression switching
    document.querySelectorAll('.controls button').forEach(btn => {{
      btn.addEventListener('click', () => {{
        // Update active state
        document.querySelectorAll('.controls button').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        
        const expr = btn.dataset.expr;
        console.log('Switching to expression:', expr);
        
        // TODO: Load actual Cubism model and apply expression
        placeholder.text = `{{expr}}`;
      }});
    }});
    
    // Auto-play idle animation
    let angle = 0;
    function idleAnimation() {{
      angle += 0.02;
      placeholder.x = 256 + Math.sin(angle) * 5;
      requestAnimationFrame(idleAnimation);
    }}
    idleAnimation();
  </script>
</body>
</html>'''
    
    def _serve_webgl_viewer(self, params: Dict[str, List[str]]):
        """Serve WebGL viewer page for embedding in Flutter iframe."""
        model_id = params.get('model', [''])[0]
        expr = params.get('expr', ['neutral'])[0]
        
        html = '''<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Live2D WebGL View</title>
  <style>
    body {{ margin: 0; overflow: hidden; background: transparent; }}
    #viewer {{ width: 100vw; height: 100vh; display: flex; justify-content: center; align-items: center; }}
  </style>
</head>
<body>
  <div id="viewer">
    <!-- PixiJS canvas will be injected here -->
    <div style="color: white; font-size: 16px;">Loading Live2D model...</div>
  </div>
  
  <script>
    async function loadLive2D() {{
      try {{
        // Fetch model metadata
        const resp = await fetch('/models');
        const data = await resp.json();
        
        const models = data.models;
        const target = models.find(m => m.id === '{model_id}' || m.path.includes('{model_id}'));
        
        if (!target) {{
          console.error('Model not found');
          return;
        }}
        
        // Create PixiJS application
        const app = new PIXI.Application({
          width: 400,
          height: 400,
          backgroundColor: 0x1a1a1a,
          autoDensity: true,
          antialias: true
        });
        document.getElementById('viewer').appendChild(app.view);
        
        // TODO: Actually load Cubism model using pixi-live2d-display library
        // For demo, show placeholder
        const placeholder = new PIXI.Text('{expr}', {{
          fontSize: 24,
          fill: '#ffffff'
        }});
        placeholder.anchor.set(0.5);
        placeholder.x = 200;
        placeholder.y = 200;
        app.stage.addChild(placeholder);
        
        // Idle animation
        let t = 0;
        function animate() {{
          t += 0.02;
          placeholder.position.x = 200 + Math.sin(t) * 3;
          requestAnimationFrame(animate);
        }}
        animate();
        
        // Post message parent frame (Flutter web view)
        window.parent.postMessage({{type: 'LIVE2D_READY', model: '{model_id}', expr: '{expr}'}}, '*');
        
      }} catch (e) {{
        console.error('Failed to load Live2D:', e);
      }}
    }}
    
    loadLive2D();
  </script>
</body>
</html>'''
        
        self._send_html(html)
    
    def log_message(self, format, *args):
        """Suppress default logging."""
        pass


def main():
    parser = argparse.ArgumentParser(description="Live2D Rendering HTTP Service")
    parser.add_argument("--port", type=int, default=39252, help="HTTP port")
    args = parser.parse_args()
    
    print(f"Starting Live2D Rendering Service on port {args.port}...")
    print(f"Game root: {Live2DRendererService.GAME_ROOT}")
    print(f"Models directory: {Live2DRendererService.L2D_DIR}")
    print(f"Cache directory: {Live2DRendererService.CACHE_DIR}")
    
    service = Live2DRendererService(port=args.port)
    
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
