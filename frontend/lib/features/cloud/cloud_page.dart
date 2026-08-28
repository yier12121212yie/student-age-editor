import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';

// 已下线的云盘类型：旧配置条目仍显示，但不可再测试/保存（后端已移除驱动）
const Set<String> _kRemovedDrivers = {'aliyundrive','aliyun','quark','189','tianyi'};

class CloudPage extends StatefulWidget {
  const CloudPage({super.key, required this.state});
  final AppState state;
  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  List<dynamic> _providers = [];
  List<String> _drivers = ['local','webdav','openlist','alist','baidu_netdisk','123','google_drive','onedrive'];
  // driver schemas loaded for future dynamic form generation
  Map<String, dynamic> _driverSchemas = {};
  String? _selectedProvider;
  bool _loading = false;
  String? _selectedMod;
  List<dynamic> _localFiles = [];
  List<dynamic> _remoteFiles = [];
  bool _loadingRemote = false;
  final Set<String> _checked = {};
  String _direction = 'upload';
  bool _busy = false;
  bool _dryRun = false;
  bool _deleteExtra = false;
  dynamic _syncResult;
  Map<String, dynamic>? _syncStatus;
  Timer? _pollTimer;
  String _localSearch = '';
  // realtime sync
  Map<String, dynamic>? _rtConfig;
  Map<String, dynamic>? _rtStatus;
  Timer? _rtPollTimer;
  bool _rtLoading = false;

  @override
  void initState() {
    super.initState();
    _loadProviders();
    _loadSchemas();
    _loadRealtimeStatus();
    _startRealtimePolling();
    // auto select first mod if available
    if (widget.state.mods.isNotEmpty) {
      _selectedMod = widget.state.mods.first.name;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadFiles());
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _rtPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadProviders() async {
    setState(()=>_loading=true);
    try {
      final r = await ApiClient.instance.get('/api/cloud/providers');
      setState((){
        _providers = (r['providers'] as List?) ?? [];
        final dr = (r['drivers'] as List?)?.cast<String>();
        if (dr!=null && dr.isNotEmpty) _drivers = dr;
        if (_providers.isNotEmpty && _selectedProvider==null) {
          _selectedProvider = _providers.first['id'] as String?;
        }
      });
      if (_selectedProvider != null && _selectedMod != null) _loadRemote();
    } catch(e){ _showErr(e.toString()); } finally { setState(()=>_loading=false); }
  }

  Future<void> _loadSchemas() async {
    try {
      final r = await ApiClient.instance.get('/api/cloud/drivers');
      setState(()=> _driverSchemas = (r['drivers'] as Map<String,dynamic>?) ?? {});
    } catch (_) {}
  }

  // ---------- realtime ----------
  Future<void> _loadRealtimeStatus() async {
    try {
      final r = await ApiClient.instance.get('/api/cloud/realtime/status');
      if (!mounted) return;
      setState((){
        _rtStatus = r;
        _rtConfig = r['config'] as Map<String,dynamic>?;
      });
    } catch (_) {}
  }

  void _startRealtimePolling(){
    _rtPollTimer?.cancel();
    _rtPollTimer = Timer.periodic(const Duration(seconds: 2), (_)=> _loadRealtimeStatus());
  }

  Future<void> _toggleRealtime(bool enable) async {
    if (_rtLoading) return;
    setState(()=>_rtLoading=true);
    try{
      if (enable) {
        if (_selectedProvider==null || _selectedProvider!.isEmpty) {
          _showErr('请先选择云存储');
          return;
        }
        if (_selectedMod==null || _selectedMod!.isEmpty) {
          _showErr('请先选择 Mod');
          return;
        }
        final cfg = <String,dynamic>{
          'provider_id': _selectedProvider,
          'mod_name': _selectedMod,
          'direction': _direction,
          'enabled': true,
        };
        // preserve existing intervals if present
        if (_rtConfig!=null) {
          if (_rtConfig!['debounce_ms']!=null) cfg['debounce_ms']=_rtConfig!['debounce_ms'];
          if (_rtConfig!['poll_interval_ms']!=null) cfg['poll_interval_ms']=_rtConfig!['poll_interval_ms'];
          if (_rtConfig!['remote_poll_interval_ms']!=null) cfg['remote_poll_interval_ms']=_rtConfig!['remote_poll_interval_ms'];
          if (_rtConfig!['delete_extra']!=null) cfg['delete_extra']=_rtConfig!['delete_extra'];
          if (_rtConfig!['watch_all_mods']!=null) cfg['watch_all_mods']=_rtConfig!['watch_all_mods'];
        }
        await ApiClient.instance.post('/api/cloud/realtime/start', body: cfg);
        _showInfo('实时同步已开启');
      } else {
        await ApiClient.instance.post('/api/cloud/realtime/stop');
        _showInfo('实时同步已关闭');
      }
      await _loadRealtimeStatus();
    } catch(e){ _showErr(e.toString()); } finally { if(mounted) setState(()=>_rtLoading=false); }
  }

  Future<void> _updateRealtimeConfig(Map<String,dynamic> patch) async {
    try{
      await ApiClient.instance.post('/api/cloud/realtime/config', body: patch);
      await _loadRealtimeStatus();
    } catch(e){ _showErr(e.toString()); }
  }

  Widget _buildRealtimePanel(){
    final rt = _rtStatus;
    final cfg = _rtConfig ?? rt?['config'] as Map<String,dynamic>?;
    final enabled = rt?['enabled']==true || rt?['running']==true;
    final running = rt?['running']==true;
    final pending = rt?['pending_count'] as int? ?? 0;
    final lastSync = rt?['last_sync'] as String? ?? '';
    final error = rt?['error'] as String? ?? '';
    final watching = (rt?['watching_mods'] as List?)?.cast<String>() ?? [];
    final stats = rt?['stats'] as Map<String,dynamic>?;
    final events = (rt?['events'] as List?) ?? [];
    final direction = cfg?['direction'] as String? ?? _direction;
    return Container(
      margin: const EdgeInsets.only(bottom:10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: enabled ? const Color(0xFF4F6EF7).withValues(alpha: 0.4) : const Color(0xFF2A2A2E)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
        Row(children:[
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: enabled ? const Color(0xFF4F6EF7) : const Color(0xFF2A2A2E), borderRadius: BorderRadius.circular(6)),
            child: Icon(enabled ? FluentIcons.cloud_sync_24_regular : FluentIcons.cloud_off_24_regular, size:14, color: Colors.white),
          ),
          const SizedBox(width:8),
          const Flexible(
            child: Text('实时同步', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize:12, color: Color(0xFFD4D4D8), fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width:6),
          Flexible(child: Container(
            padding: const EdgeInsets.symmetric(horizontal:6, vertical:2),
            decoration: BoxDecoration(color: running ? const Color(0xFF0F7B0F).withValues(alpha:0.15) : const Color(0xFF2A2A2E), borderRadius: BorderRadius.circular(4), border: Border.all(color: running ? const Color(0xFF0F7B0F).withValues(alpha:0.3) : Colors.transparent)),
            child: Row(mainAxisSize: MainAxisSize.min, children:[
              Container(width:6, height:6, decoration: BoxDecoration(color: running ? const Color(0xFF0F7B0F) : const Color(0xFF6E6E76), shape: BoxShape.circle)),
              const SizedBox(width:4),
              Flexible(child: Text(running ? '运行中' : (enabled ? '已启用' : '已停止'), maxLines:1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize:10, color: running ? const Color(0xFF0F7B0F) : const Color(0xFF8B8B93)))),
            ]),
          ),
          ),
          if (pending>0) ...[
            const SizedBox(width:6),
            Flexible(child: Container(padding: const EdgeInsets.symmetric(horizontal:6, vertical:2), decoration: BoxDecoration(color: const Color(0xFFF2C25C).withValues(alpha:0.15), borderRadius: BorderRadius.circular(4)), child: Text('待同步 $pending', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize:10, color: Color(0xFFF2C25C)))))
          ],
          const Spacer(),
          if (_rtLoading) const SizedBox(width:12, height:12, child: fluent.ProgressRing(strokeWidth:2)),
          const SizedBox(width:8),
          fluent.ToggleSwitch(
            checked: enabled,
            onChanged: (v)=> _toggleRealtime(v),
          ),
        ]),
        const SizedBox(height:8),
        // config row
        Wrap(spacing:8, runSpacing:6, crossAxisAlignment: WrapCrossAlignment.center, children:[
          Row(mainAxisSize: MainAxisSize.min, children:[
            const Text('方向', style: TextStyle(fontSize:10, color: Color(0xFF9B9BA3))),
            const SizedBox(width:6),
            _rtDirectionChip('upload', '上传', FluentIcons.arrow_upload_24_regular, direction),
            const SizedBox(width:4),
            _rtDirectionChip('download', '下载', FluentIcons.arrow_download_24_regular, direction),
            const SizedBox(width:4),
            _rtDirectionChip('sync', '双向', FluentIcons.arrow_sync_24_regular, direction),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children:[
            fluent.Checkbox(
              checked: cfg?['delete_extra']==true,
              onChanged: (v)=> _updateRealtimeConfig({'delete_extra': v==true}),
            ),
            const SizedBox(width:4),
            const Text('同步删除', style: TextStyle(fontSize:10, color: Color(0xFF9B9BA3))),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children:[
            fluent.Checkbox(
              checked: cfg?['watch_all_mods']==true,
              onChanged: (v){
                _updateRealtimeConfig({'watch_all_mods': v==true});
                if (v==true) _showInfo('将监听全部 Mod');
              },
            ),
            const SizedBox(width:4),
            const Text('全部 Mod', style: TextStyle(fontSize:10, color: Color(0xFF9B9BA3))),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children:[
            fluent.Checkbox(
              checked: cfg?['auto_start']==true,
              onChanged: (v)=> _updateRealtimeConfig({'auto_start': v==true}),
            ),
            const SizedBox(width:4),
            const Text('自动启动', style: TextStyle(fontSize:10, color: Color(0xFF9B9BA3))),
          ]),
        ]),
        if (watching.isNotEmpty) Padding(
          padding: const EdgeInsets.only(top:6),
          child: Wrap(spacing:4, runSpacing:4, children: watching.map((m)=> Container(
            padding: const EdgeInsets.symmetric(horizontal:6, vertical:2),
            decoration: BoxDecoration(color: const Color(0xFF2B2B31), borderRadius: BorderRadius.circular(4)),
            child: Text(m, style: const TextStyle(fontSize:10, color: Color(0xFF9B9BA3))),
          )).toList()),
        ),
        if (lastSync.isNotEmpty || (stats!=null && stats.isNotEmpty)) Padding(
          padding: const EdgeInsets.only(top:6),
          child: Row(children:[
            if (lastSync.isNotEmpty) Text('上次 $lastSync', style: const TextStyle(fontSize:10, color: Color(0xFF6E6E76))),
            if (stats!=null) ...[
              const SizedBox(width:8),
              Text('本地+${stats['local_changes'] ?? 0} 远端+${stats['remote_changes'] ?? 0} 成功${stats['sync_success'] ?? 0}', style: const TextStyle(fontSize:10, color: Color(0xFF6E6E76))),
            ],
          ]),
        ),
        if (error.isNotEmpty) Padding(
          padding: const EdgeInsets.only(top:6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal:8, vertical:6),
            decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha:0.08), borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.redAccent.withValues(alpha:0.2))),
            child: Row(children:[
              const Icon(FluentIcons.error_circle_24_regular, size:12, color: Colors.redAccent),
              const SizedBox(width:6),
              Expanded(child: Text(error, style: const TextStyle(fontSize:10, color: Colors.redAccent), maxLines:2, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ),
        if ((rt?['pending_files'] as List?)?.isNotEmpty == true) Padding(
          padding: const EdgeInsets.only(top:6),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: const Color(0xFF1E1E23), borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFF2A2A2E))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
              const Text('待处理', style: TextStyle(fontSize:10, color: Color(0xFF8B8B93))),
              const SizedBox(height:4),
              ...((rt!['pending_files'] as List).take(5).map((f)=> Padding(
                padding: const EdgeInsets.only(bottom:2),
                child: Text(f.toString(), style: const TextStyle(fontSize:10, color: Color(0xFFF2C25C)), overflow: TextOverflow.ellipsis),
              ))),
            ]),
          ),
        ),
        if (events.isNotEmpty) ...[
          const SizedBox(height:8),
          Container(
            height: 92,
            decoration: BoxDecoration(color: const Color(0xFF1E1E23), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFF2A2A2E))),
            child: Column(children:[
              Container(
                padding: const EdgeInsets.symmetric(horizontal:8, vertical:4),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF2A2A2E)))),
                child: Row(children:[
                  const Text('事件', style: TextStyle(fontSize:10, color: Color(0xFF8B8B93))),
                  const Spacer(),
                  GestureDetector(onTap: _loadRealtimeStatus, child: const Icon(FluentIcons.arrow_sync_24_regular, size:10, color: Color(0xFF6E6E76))),
                ]),
              ),
              Expanded(child: ListView.builder(
                itemCount: events.length > 20 ? 20 : events.length,
                itemBuilder: (c,i){
                  final e = events[i] as Map;
                  final lvl = e['level'] as String? ?? 'info';
                  Color col = const Color(0xFF9B9BA3);
                  if (lvl=='error') col = Colors.redAccent;
                  else if (lvl=='warn') col = const Color(0xFFF2C25C);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal:8, vertical:2),
                    child: Row(children:[
                      Container(width:6, height:6, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
                      const SizedBox(width:6),
                      Text(e['time'] as String? ?? '', style: const TextStyle(fontSize:9, color: Color(0xFF6E6E76))),
                      const SizedBox(width:6),
                      Expanded(child: Text(e['msg'] as String? ?? '', style: TextStyle(fontSize:10, color: col), overflow: TextOverflow.ellipsis)),
                    ]),
                  );
                },
              )),
            ]),
          ),
        ],
        const SizedBox(height:6),
        Row(children:[
          fluent.Button(
            onPressed: _loadRealtimeStatus,
            child: const Text('刷新状态', style: TextStyle(fontSize:11)),
          ),
          const SizedBox(width:8),
          fluent.Button(
            onPressed: () async {
              try{
                final r = await ApiClient.instance.get('/api/cloud/realtime/events', query: {'limit':'30'});
                final ev = (r['events'] as List?) ?? [];
                if (!mounted) return;
                fluent.showDialog(context: context, builder:(ctx)=> fluent.ContentDialog(
                  title: const Text('实时事件'),
                  content: SizedBox(width:420, height:300, child: ListView(
                    children: ev.map((e)=> Padding(
                      padding: const EdgeInsets.only(bottom:4),
                      child: Text("${e['time']} [${e['level']}] ${e['msg']}", style: const TextStyle(fontSize:10)),
                    )).toList(),
                  )),
                  actions:[fluent.Button(onPressed:()=>Navigator.pop(ctx), child: const Text('关闭'))],
                ));
              }catch(e){ _showErr(e.toString()); }
            },
            child: const Text('查看全部', style: TextStyle(fontSize:11)),
          ),
          const Spacer(),
          Flexible(child: Text('防抖 ${cfg?['debounce_ms'] ?? 2000}ms  轮询 ${cfg?['poll_interval_ms'] ?? 2000}ms', maxLines:1, overflow:TextOverflow.ellipsis, style: const TextStyle(fontSize:9, color: Color(0xFF6E6E76)))),
        ]),
      ]),
    );
  }

  Widget _rtDirectionChip(String value, String label, IconData icon, String current){
    final sel = current==value;
    final content = Row(mainAxisSize: MainAxisSize.min, children:[Icon(icon, size:10, color: sel? Colors.white: const Color(0xFF9B9BA3)), const SizedBox(width:3), Text(label, style: TextStyle(fontSize:10, color: sel? Colors.white: const Color(0xFFD4D4D8)))]);
    if(sel){
      return fluent.FilledButton(onPressed: ()=> _updateRealtimeConfig({'direction': value}), child: content);
    }
    return fluent.Button(onPressed: ()=> _updateRealtimeConfig({'direction': value}), child: content);
  }


  String _driverLabel(String t){
    const map = {'baidu_netdisk':'百度网盘','baidu':'百度网盘','aliyundrive':'阿里云盘（已下线）','aliyun':'阿里云盘（已下线）','quark':'夸克网盘（已下线）','123':'123云盘','123pan':'123云盘','189':'天翼云盘（已下线）','tianyi':'天翼云盘（已下线）','google_drive': 'Google Drive','gdrive':'Google Drive','onedrive':'OneDrive','local':'本地目录','webdav':'WebDAV','openlist':'OpenList','alist':'Alist'};
    return map[t] ?? t;
  }
  IconData _driverIcon(String t){
    if (t.contains('baidu')) return FluentIcons.cloud_24_regular;
    if (t.contains('123')) return FluentIcons.folder_24_regular;
    if (t.contains('google')) return FluentIcons.globe_24_regular;
    if (t.contains('onedrive')) return FluentIcons.cloud_24_regular;
    if (t=='webdav') return FluentIcons.link_24_regular;
    if (t=='local') return FluentIcons.folder_24_regular;
    return FluentIcons.server_24_regular;
  }

  String _driverHelp(String t){
    const helps = {
      'local': '本地目录映射：填本机路径，用于测试。无需网络。',
      'webdav': 'WebDAV：兼容坚果云/Alist/Nextcloud。需填 URL+账号密码。',
      'openlist': 'OpenList/Alist 代理：填你的 OpenList 地址和 Token，一键复用 40+ 存储。',
      'baidu_netdisk': '百度网盘：优先填 refresh_token；也可走 OpenList 代理更稳定。',
      '123': '123云盘：填账号密码直连，或走 OpenList。',
      'google_drive': 'Google Drive：需 OAuth refresh_token，或走 OpenList。注意：OpenList 地址填你的 OpenList 实例 (如 http://127.0.0.1:5244)，不要填 https://api.oplist.org/.../renewapi（那是 Token 刷新接口，会报 403/1010）',
      'onedrive': 'OneDrive：需 refresh_token + Client ID（Azure 应用），或走 OpenList。默认 Client ID f0e3cad9... 仅示例，请填你自己的 Azure 应用 ID，否则报 700016',
    };
    return helps[t] ?? '';
  }

  Future<void> _addProvider({Map? editTarget}) async {
    final isEdit = editTarget != null;
    final nameCtrl = TextEditingController(text: isEdit ? (editTarget['name'] ?? '') : '');
    final urlCtrl = TextEditingController(text: isEdit ? (editTarget['config']?['url'] ?? editTarget['config']?['root'] ?? '') : '');
    final userCtrl = TextEditingController(text: isEdit ? (editTarget['config']?['username'] ?? editTarget['config']?['user'] ?? '') : '');
    final passCtrl = TextEditingController(text: isEdit ? '' : ''); // password masked, leave blank to keep
    final tokenCtrl = TextEditingController(text: isEdit ? '' : '');
    final refreshCtrl = TextEditingController(text: isEdit ? '' : '');
    final mountCtrl = TextEditingController(text: isEdit ? (editTarget['config']?['mount_path'] ?? '') : '');
    final gClientIdCtrl = TextEditingController(text: isEdit ? (editTarget['config']?['client_id'] ?? '') : '');
    final gClientSecretCtrl = TextEditingController(text: isEdit ? '' : '');
    final oClientIdCtrl = TextEditingController(text: isEdit ? (editTarget['config']?['client_id'] ?? '') : '');
    final oClientSecretCtrl = TextEditingController(text: isEdit ? '' : '');
    final rootCtrl = TextEditingController(text: isEdit ? (editTarget['remote_root'] ?? 'mods') : 'mods');
    final openUrlCtrl = TextEditingController(text: isEdit ? (editTarget['config']?['openlist_url'] ?? '') : '');
    final openTokenCtrl = TextEditingController(text: isEdit ? '' : '');
    final rootLocalCtrl = TextEditingController(text: isEdit ? (editTarget['config']?['root'] ?? '') : '');
    String type = isEdit ? (editTarget['type'] as String? ?? 'webdav') : 'webdav';
    String? errorText;
    bool testing = false;
    await fluent.showDialog<void>(context: context, builder: (ctx)=>StatefulBuilder(builder: (ctx,setDlg){
      Widget field(String label, TextEditingController c, {String? hint, bool obscure=false}){
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children:[Text(label, style: const TextStyle(fontSize:11, color: Color(0xFF9B9BA3))), const SizedBox(height:3), fluent.TextBox(controller:c, placeholder:hint, obscureText:obscure), const SizedBox(height:6)]);
      }
      final help = _driverHelp(type);
      return fluent.ContentDialog(
        title: Text(isEdit ? '编辑云存储' : '新增云存储'),
        content: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
          fluent.ComboBox<String>(value: type, isExpanded:true, items: (_drivers.contains(type) ? _drivers : [type, ..._drivers]).map((d)=>fluent.ComboBoxItem(value:d, child: Text('${_driverLabel(d)} ($d)', overflow:TextOverflow.ellipsis))).toList(), onChanged:(v)=>setDlg(()=>type=v??type)),
          if (help.isNotEmpty) Padding(padding: const EdgeInsets.only(top:6, bottom:8), child: Text(help, style: const TextStyle(fontSize:10, color: Color(0xFF8B8B93)))),
          field('名称 *', nameCtrl, hint: _driverLabel(type)),
          if (type=='local') field('本地根目录 *', rootLocalCtrl, hint: r'D:/CloudMods 或 /tmp/mods'),
          if (type=='webdav') ...[field('WebDAV 地址 *', urlCtrl, hint: 'https://dav.example.com/'), field('用户名', userCtrl), field('密码', passCtrl, obscure:true)],
          if (type=='openlist' || type=='alist') ...[field('OpenList 地址 *', urlCtrl, hint:'http://host:5244'), field('Token', tokenCtrl, obscure:true)],
          if (type=='baidu_netdisk' || type=='baidu') ...[field('refresh_token', refreshCtrl, hint:'bduss 或官方 refresh_token'), field('OpenList 地址(可选，更稳定)', openUrlCtrl, hint:'http://host:5244'), field('挂载路径', mountCtrl, hint:'/baidu')],
          if (type=='123' || type=='123pan') ...[field('用户名/邮箱 *', userCtrl), field('密码 *', passCtrl, obscure:true), field('OpenList 地址(可选)', openUrlCtrl), field('挂载路径', mountCtrl, hint:'/123')],
          if (type=='google_drive' || type=='gdrive') ...[field('refresh_token *', refreshCtrl, hint:'1//... 完整 refresh_token'), field('Client ID (直连时选填，留空则尝试公共刷新)', gClientIdCtrl, hint:'xxx.apps.googleusercontent.com'), field('Client Secret (直连时选填)', gClientSecretCtrl, obscure:true), field('OpenList 地址', openUrlCtrl, hint:'http://127.0.0.1:5244（自建时填）'), field('挂载路径', mountCtrl, hint:'/gdrive (OpenList 中挂载名)'),],
          if (type=='onedrive') ...[field('refresh_token *', refreshCtrl, hint:'M.R3_BAY... 长串'), field('Client ID *', oClientIdCtrl, hint:'如 f0e3cad9-1bf3-4006-9999-1a1a1e1a4ae0 (oplist.org 公共)'), field('Client Secret', oClientSecretCtrl, obscure:true), field('OpenList 地址', openUrlCtrl, hint:'http://127.0.0.1:5244'), field('挂载路径', mountCtrl, hint:'/onedrive'),],
          field('远端根', rootCtrl, hint:'mods'),
          if (errorText!=null) Padding(padding: const EdgeInsets.only(top:6), child: Text(errorText!, style: const TextStyle(fontSize:11, color: Colors.red))),
        ])),
        actions:[
          fluent.Button(onPressed:()=>Navigator.pop(ctx), child: const Text('取消')),
          fluent.Button(onPressed: testing ? null : () async {
            setDlg(()=>testing=true);
            try{
              final testCfg = <String,dynamic>{};
              if (type=='local') testCfg['root']=rootLocalCtrl.text.trim();
              else if (type=='webdav'){ testCfg['url']=urlCtrl.text.trim(); testCfg['username']=userCtrl.text.trim(); if (passCtrl.text.isNotEmpty) testCfg['password']=passCtrl.text; }
              else if (type=='openlist' || type=='alist'){ testCfg['url']=urlCtrl.text.trim(); if(tokenCtrl.text.isNotEmpty) testCfg['token']=tokenCtrl.text.trim(); }
              else if (type=='baidu_netdisk' || type=='baidu'){ if(refreshCtrl.text.isNotEmpty) testCfg['refresh_token']=refreshCtrl.text.trim(); testCfg['openlist_url']=openUrlCtrl.text.trim(); if(openTokenCtrl.text.isNotEmpty) testCfg['openlist_token']=openTokenCtrl.text.trim(); testCfg['mount_path']=mountCtrl.text.trim().isEmpty?'/baidu':mountCtrl.text.trim(); }
              else if (type=='123' || type=='123pan'){ testCfg['username']=userCtrl.text.trim(); if(passCtrl.text.isNotEmpty) testCfg['password']=passCtrl.text; testCfg['openlist_url']=openUrlCtrl.text.trim(); testCfg['mount_path']=mountCtrl.text.trim().isEmpty?'/123':mountCtrl.text.trim(); }
              else if (type=='google_drive' || type=='gdrive'){
                final _openUrl = openUrlCtrl.text.trim();
                if(_openUrl.contains('renewapi') || _openUrl.contains('googleui')){ setDlg(()=>errorText='OpenList 地址填写错误：请勿填 https://api.oplist.org/.../renewapi（那是 Token 刷新接口）。直连请留空该字段；走 OpenList 请填你的 OpenList 实例如 http://127.0.0.1:5244'); return; }
                if(refreshCtrl.text.isNotEmpty) testCfg['refresh_token']=refreshCtrl.text.trim(); 
                if(gClientIdCtrl.text.trim().isNotEmpty) testCfg['client_id']=gClientIdCtrl.text.trim();
                if(gClientSecretCtrl.text.isNotEmpty) testCfg['client_secret']=gClientSecretCtrl.text.trim();
                testCfg['openlist_url']=_openUrl; testCfg['mount_path']=mountCtrl.text.trim().isEmpty?'/gdrive':mountCtrl.text.trim(); }
              else if (type=='onedrive'){ if(refreshCtrl.text.isNotEmpty) testCfg['refresh_token']=refreshCtrl.text.trim(); if(oClientIdCtrl.text.trim().isNotEmpty) testCfg['client_id']=oClientIdCtrl.text.trim(); if(oClientSecretCtrl.text.isNotEmpty) testCfg['client_secret']=oClientSecretCtrl.text.trim(); testCfg['openlist_url']=openUrlCtrl.text.trim(); testCfg['mount_path']=mountCtrl.text.trim().isEmpty?'/onedrive':mountCtrl.text.trim(); }
              await ApiClient.instance.post('/api/cloud/test', body:{'type':type,'config':testCfg});
              setDlg(()=>errorText=null);
              _showInfo('连接成功');
            }catch(e){ setDlg(()=>errorText=e.toString()); } finally { setDlg(()=>testing=false); }
          }, child: Text(testing?'测试中...':'测试连接')),
          fluent.FilledButton(onPressed:() async {
            if (_kRemovedDrivers.contains(type)) { setDlg(()=>errorText='该云盘已停止支持：请删除后改用 OpenList 代理云存储'); return; }
            final name = nameCtrl.text.trim();
            if (name.isEmpty) { setDlg(()=>errorText='名称不能为空'); return; }
            if (type=='local' && rootLocalCtrl.text.trim().isEmpty) { setDlg(()=>errorText='本地根目录不能为空'); return; }
            if ((type=='webdav' || type=='openlist' || type=='alist') && urlCtrl.text.trim().isEmpty) { setDlg(()=>errorText='地址不能为空'); return; }
            Navigator.pop(ctx);
            final cfg=<String,dynamic>{};
            if (type=='local') cfg['root']=rootLocalCtrl.text.trim();
            else if (type=='webdav'){ cfg['url']=urlCtrl.text.trim(); cfg['username']=userCtrl.text.trim(); if(passCtrl.text.isNotEmpty) cfg['password']=passCtrl.text; }
            else if (type=='openlist' || type=='alist'){ cfg['url']=urlCtrl.text.trim(); if(tokenCtrl.text.isNotEmpty) cfg['token']=tokenCtrl.text.trim(); }
            else if (type=='baidu_netdisk' || type=='baidu'){ if(refreshCtrl.text.isNotEmpty) cfg['refresh_token']=refreshCtrl.text.trim(); cfg['openlist_url']=openUrlCtrl.text.trim(); if(openTokenCtrl.text.isNotEmpty) cfg['openlist_token']=openTokenCtrl.text.trim(); cfg['mount_path']=mountCtrl.text.trim().isEmpty?'/baidu':mountCtrl.text.trim(); }
            else if (type=='123' || type=='123pan'){ cfg['username']=userCtrl.text.trim(); if(passCtrl.text.isNotEmpty) cfg['password']=passCtrl.text; cfg['openlist_url']=openUrlCtrl.text.trim(); cfg['mount_path']=mountCtrl.text.trim().isEmpty?'/123':mountCtrl.text.trim(); }
            else if (type=='google_drive' || type=='gdrive'){
                final _openUrl2 = openUrlCtrl.text.trim();
                if(_openUrl2.contains('renewapi') || _openUrl2.contains('googleui')){ setDlg(()=>errorText='OpenList 地址填写错误：请勿填 api.oplist.org/.../renewapi'); return; }
                if(refreshCtrl.text.isNotEmpty) cfg['refresh_token']=refreshCtrl.text.trim(); 
                if(gClientIdCtrl.text.trim().isNotEmpty) cfg['client_id']=gClientIdCtrl.text.trim();
                if(gClientSecretCtrl.text.isNotEmpty) cfg['client_secret']=gClientSecretCtrl.text.trim();
                cfg['openlist_url']=_openUrl2; cfg['mount_path']=mountCtrl.text.trim().isEmpty?'/gdrive':mountCtrl.text.trim(); }
            else if (type=='onedrive'){ if(refreshCtrl.text.isNotEmpty) cfg['refresh_token']=refreshCtrl.text.trim(); if(oClientIdCtrl.text.trim().isNotEmpty) cfg['client_id']=oClientIdCtrl.text.trim(); if(oClientSecretCtrl.text.isNotEmpty) cfg['client_secret']=oClientSecretCtrl.text.trim(); cfg['openlist_url']=openUrlCtrl.text.trim(); cfg['mount_path']=mountCtrl.text.trim().isEmpty?'/onedrive':mountCtrl.text.trim(); }
            try{
              if(isEdit){
                await ApiClient.instance.put('/api/cloud/providers/${editTarget['id']}', body:{'name': name, 'type':type, 'config':cfg, 'remote_root':rootCtrl.text.trim()});
              } else {
                await ApiClient.instance.post('/api/cloud/providers', body:{'name': name.isEmpty? _driverLabel(type):name, 'type':type, 'config':cfg, 'remote_root':rootCtrl.text.trim()});
              }
              await _loadProviders();
              _showInfo(isEdit?'已更新':'已创建');
            }catch(e){ _showErr(e.toString()); }
          }, child: Text(isEdit ? '保存' : '创建')),
        ],
      );
    }));
  }

  Future<void> _test(String id) async { try{ await ApiClient.instance.post('/api/cloud/test', body:{'provider_id':id}); _showInfo('连接成功'); }catch(e){ _showErr(e.toString()); } }
  Future<void> _del(String id) async {
    final ok=await fluent.showDialog<bool>(context:context, builder:(ctx)=>fluent.ContentDialog(title:const Text('删除'), content:const Text('确认删除？此操作不可恢复。'), actions:[fluent.Button(onPressed:()=>Navigator.pop(ctx,false), child:const Text('取消')), fluent.FilledButton(onPressed:()=>Navigator.pop(ctx,true), child:const Text('删除'))]));
    if(ok!=true) return; try{ await ApiClient.instance.delete('/api/cloud/providers/$id'); if(_selectedProvider==id) setState(()=>_selectedProvider=null); await _loadProviders(); }catch(e){ _showErr(e.toString()); }
  }

  Future<void> _loadFiles() async {
    if(_selectedMod==null) { setState(()=>_localFiles=[]); return; }
    try{
      final r=await ApiClient.instance.get('/api/cloud/local_files', query:{'mod_name':_selectedMod!});
      final entries = (r['entries'] as List?) ?? [];
      setState(()=>_localFiles = entries);
      // 同时刷新远端
      _loadRemote();
    }catch(e){ _showErr(e.toString()); setState(()=>_localFiles=[]); }
  }

  Future<void> _loadRemote() async {
    if(_selectedProvider==null || _selectedMod==null) { setState(()=>_remoteFiles=[]); return; }
    setState(()=>_loadingRemote=true);
    try{
      final r=await ApiClient.instance.get('/api/cloud/list', query:{'provider_id':_selectedProvider!, 'mod_name':_selectedMod!});
      setState(()=>_remoteFiles = (r['objects'] as List?) ?? []);
    }catch(e){
      setState(()=>_remoteFiles=[]);
      // 非阻塞提示
      // _showErr('远端列举失败: $e');
    } finally { setState(()=>_loadingRemote=false); }
  }

  void _startPolling(){
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 600), (_) async {
      try{
        final s = await ApiClient.instance.get('/api/cloud/status');
        if(mounted) setState(()=>_syncStatus = s as Map<String,dynamic>?);
        if(s['running']!=true){
          _pollTimer?.cancel();
        }
      }catch(_){}
    });
  }

  Future<void> _syncFolder() async {
    if(_selectedProvider==null || _selectedMod==null){ _showErr('请选择云盘和 Mod'); return; }
    setState(()=>_busy=true);
    _startPolling();
    try{
      final r=await ApiClient.instance.post('/api/cloud/sync', body:{'provider_id':_selectedProvider,'direction':_direction,'mod_name':_selectedMod,'folder':true,'dry_run':_dryRun, 'delete_extra':_deleteExtra});
      _pollTimer?.cancel();
      setState(()=>_syncResult=r);
      final total = r['total'] as int? ?? (r['results'] as List?)?.length ?? 0;
      final results = (r['results'] as List?) ?? [];
      final fails = results.where((e)=> e['ok']==false).length;
      if(total==0){
        _showErr('未发现文件：Mod 空或远端空，请检查本地与远端。');
      } else if(fails>0){
        _showErr('同步完成，但有 $fails 个失败，请查看详情');
      } else {
        _showInfo('同步完成 total=$total');
      }
      _loadFiles();
    }catch(e){
      _pollTimer?.cancel();
      setState(()=>_syncResult={'error': e.toString()});
      _showErr(e.toString());
    } finally{
      setState(()=>_busy=false);
      _syncStatus=null;
      try{ final s=await ApiClient.instance.get('/api/cloud/status'); if(mounted) setState(()=>_syncStatus=s); }catch(_){}
    }
  }

  Future<void> _syncFiles() async {
    if(_checked.isEmpty){ _showErr('请勾选文件'); return; }
    if(_selectedProvider==null || _selectedMod==null){ _showErr('请选择云盘和 Mod'); return; }
    setState(()=>_busy=true);
    _startPolling();
    try{
      final r=await ApiClient.instance.post('/api/cloud/sync', body:{'provider_id':_selectedProvider,'direction':_direction,'mod_name':_selectedMod,'files':_checked.toList(),'dry_run':_dryRun});
      _pollTimer?.cancel();
      setState(()=>_syncResult=r);
      _showInfo('单文件同步完成');
      _loadFiles();
    }catch(e){
      _pollTimer?.cancel();
      setState(()=>_syncResult={'error': e.toString()});
      _showErr(e.toString());
    } finally{ setState(()=>_busy=false); }
  }

  void _showErr(String m){ if(!mounted) return; fluent.displayInfoBar(context, builder:(c,close)=>fluent.InfoBar(title:const Text('失败'), content:Text(m, maxLines:5), severity:fluent.InfoBarSeverity.error)); }
  void _showInfo(String m){ if(!mounted) return; fluent.displayInfoBar(context, builder:(c,close)=>fluent.InfoBar(title:Text(m), severity:fluent.InfoBarSeverity.success)); }

  Widget _directionChip(String value, String label, IconData icon){
    final sel = _direction==value;
    final content = Row(mainAxisSize: MainAxisSize.min, children:[Icon(icon, size:12, color: sel? Colors.white: const Color(0xFF9B9BA3)), const SizedBox(width:4), Text(label, style: TextStyle(fontSize:11, color: sel? Colors.white: const Color(0xFFD4D4D8)))]);
    if(sel){
      return fluent.FilledButton(onPressed: ()=> setState(()=> _direction=value), child: content);
    }
    return fluent.Button(onPressed: ()=> setState(()=> _direction=value), child: content);
  }

  Widget _buildProgress(){
    final s = _syncStatus;
    if(s==null || !_busy) return const SizedBox.shrink();
    final running = s['running']==true;
    final prog = s['progress'] as int? ?? 0;
    final total = s['total'] as int? ?? 0;
    final last = s['last'] as String? ?? '';
    final action = s['action'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.only(top:8, bottom:4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: const Color(0xFF1E1E23), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFF2A2A2E))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
        Row(children:[
          SizedBox(width:12, height:12, child: running ? const fluent.ProgressRing(strokeWidth:2) : const Icon(FluentIcons.checkmark_12_regular, size:12, color: Colors.green)),
          const SizedBox(width:8),
          Expanded(child: Text(running ? '同步中 $action $prog/$total' : '就绪', style: const TextStyle(fontSize:11, color: Color(0xFFD4D4D8)))),
          if(total>0) Text('$prog/$total', style: const TextStyle(fontSize:10, color: Color(0xFF8B8B93))),
        ]),
        if(total>0) Padding(padding: const EdgeInsets.only(top:6), child: fluent.ProgressBar(value: total==0? null : (prog/total*100).clamp(0,100))),
        if(last.isNotEmpty) Padding(padding: const EdgeInsets.only(top:4), child: Text(last, style: const TextStyle(fontSize:10, color: Color(0xFF6E6E76)), overflow: TextOverflow.ellipsis)),
        if(s['error']!=null && (s['error'] as String).isNotEmpty) Padding(padding: const EdgeInsets.only(top:4), child: Text('错误: ${s['error']}', style: const TextStyle(fontSize:10, color: Colors.redAccent))),
      ]),
    );
  }

  Widget _buildResult(){
    if(_syncResult==null) return const SizedBox.shrink();
    final data = _syncResult;
    List results = [];
    int total = 0;
    bool isError = false;
    String message = '';
    if(data is Map){
      if(data.containsKey('error')) { isError=true; message=data['error'].toString(); }
      results = (data['results'] as List?) ?? [];
      total = data['total'] as int? ?? results.length;
      message = data['message'] as String? ?? message;
    }
    final okCount = results.where((e)=>e['ok']==true && !(e['action']?.toString().contains('skip')??false)).length;
    final skipCount = results.where((e)=>e['action']?.toString().contains('skip')??false).length;
    final failCount = results.where((e)=>e['ok']==false).length;
    return Container(
      margin: const EdgeInsets.only(top:8),
      decoration: BoxDecoration(color: const Color(0xFF1E1E23), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFF2A2A2E))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children:[
        Container(
          padding: const EdgeInsets.symmetric(horizontal:10, vertical:8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF2A2A2E)))),
          child: Row(children:[
            Text(isError? '失败' : '结果', style: TextStyle(fontSize:11, color: isError? Colors.redAccent: const Color(0xFFD4D4D8), fontWeight: FontWeight.w600)),
            const SizedBox(width:8),
            if(!isError) ...[
              _badge('$okCount 成功', const Color(0xFF0F7B0F)),
              const SizedBox(width:6),
              _badge('$skipCount 跳过', const Color(0xFF6E6E76)),
              if(failCount>0) ...[const SizedBox(width:6), _badge('$failCount 失败', Colors.redAccent)],
              const Spacer(),
              Text('total $total', style: const TextStyle(fontSize:10, color: Color(0xFF8B8B93))),
            ] else ...[
              const Spacer(),
            ],
            const SizedBox(width:8),
            fluent.Button(onPressed: ()=>setState(()=>_syncResult=null), child: const Text('清除', style: TextStyle(fontSize:10))),
          ]),
        ),
        if(isError) Padding(padding: const EdgeInsets.all(10), child: SelectableText(message, style: const TextStyle(fontSize:11, color: Colors.redAccent))),
        if(message.isNotEmpty && !isError) Padding(padding: const EdgeInsets.all(10), child: Text(message, style: const TextStyle(fontSize:11, color: Color(0xFFD4D4D8)))),
        if(results.isNotEmpty) SizedBox(
          height: 160,
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (c,i){
              final e = results[i] as Map;
              final rel = e['rel'] as String? ?? '';
              final ok = e['ok']==true;
              final action = e['action'] as String? ?? '';
              final err = e['error'] as String?;
              Color col;
              IconData icon;
              if(!ok){ col=Colors.redAccent; icon=FluentIcons.error_circle_24_regular; }
              else if(action.contains('skip')){ col=const Color(0xFF8B8B93); icon=FluentIcons.subtract_24_regular; }
              else if(action.contains('upload')){ col=const Color(0xFF4F6EF7); icon=FluentIcons.arrow_upload_24_regular; }
              else if(action.contains('download')){ col=const Color(0xFF0F7B0F); icon=FluentIcons.arrow_download_24_regular; }
              else { col=const Color(0xFFD4D4D8); icon=FluentIcons.checkmark_12_regular; }
              return Container(
                padding: const EdgeInsets.symmetric(horizontal:10, vertical:5),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: const Color(0xFF2A2A2E).withValues(alpha: 0.5)))),
                child: Row(children:[
                  Icon(icon, size:12, color: col),
                  const SizedBox(width:8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
                    Text(rel, style: const TextStyle(fontSize:11, color: Color(0xFFD4D4D8)), overflow: TextOverflow.ellipsis),
                    Text(ok ? action : (err ?? 'error'), style: TextStyle(fontSize:10, color: ok? const Color(0xFF8B8B93): Colors.redAccent), overflow: TextOverflow.ellipsis),
                  ])),
                ]),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(
            child: SelectableText(const JsonEncoder.withIndent('  ').convert(_syncResult), style: const TextStyle(fontSize:9, fontFamily:'Consolas', color:Color(0xFF6E6E76))),
          ),
        ),
      ]),
    );
  }

  Widget _badge(String text, Color color){
    return Container(
      padding: const EdgeInsets.symmetric(horizontal:6, vertical:2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4), border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Text(text, style: TextStyle(fontSize:10, color: color)),
    );
  }

  @override
  Widget build(BuildContext context){
    final mods = widget.state.mods;
    // 本地搜索过滤
    final filteredLocal = _localFiles.where((e){
      final name = (e['name'] as String? ?? '').toLowerCase();
      return name.contains(_localSearch.toLowerCase());
    }).toList();
    return LayoutBuilder(builder: (ctx, cons){
      final narrow = cons.maxWidth < 560;
      final providerPane = Container(
        decoration: BoxDecoration(color: const Color(0xFF1A1A1E), border: Border(right: narrow? BorderSide.none : const BorderSide(color: Color(0xFF2A2A2E)), bottom: narrow? const BorderSide(color: Color(0xFF2A2A2E)) : BorderSide.none)),
        child: Column(children:[
          Container(height:32, padding:const EdgeInsets.symmetric(horizontal:12), alignment:Alignment.centerLeft, child: Row(children:[
            const Text('云盘', style:TextStyle(fontSize:11, color:Color(0xFFD4D4D8), fontWeight: FontWeight.w600)),
            const SizedBox(width:6),
            Container(padding: const EdgeInsets.symmetric(horizontal:6, vertical:1), decoration: BoxDecoration(color: const Color(0xFF2B2B31), borderRadius: BorderRadius.circular(4)), child: Text('${_providers.length}', style: const TextStyle(fontSize:10, color: Color(0xFF9B9BA3)))),
            const Spacer(),
            Tooltip(message: '刷新', child: GestureDetector(onTap:_loadProviders, child:const Icon(FluentIcons.arrow_sync_24_regular, size:14, color:Color(0xFF8B8B93)))),
            const SizedBox(width:10),
            Tooltip(message: '新增', child: GestureDetector(onTap:()=>_addProvider(), child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: const Color(0xFF4F6EF7), borderRadius: BorderRadius.circular(4)), child: const Icon(FluentIcons.add_24_regular, size:12, color: Colors.white)))),
          ])),
          if(_providers.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal:10, vertical:6), color: const Color(0xFF1E1E23), child: Row(children:[
            const Icon(FluentIcons.info_24_regular, size:10, color: Color(0xFF6E6E76)),
            const SizedBox(width:6),
            const Expanded(child: Text('点名称选中，右侧展示文件对比。建议优先用 OpenList 代理', style: TextStyle(fontSize:9, color: Color(0xFF6E6E76)))),
          ])),
          Expanded(child: _loading? const Center(child:SizedBox(width:20,height:20, child:fluent.ProgressRing(strokeWidth:2))) : ListView.builder(itemCount:_providers.length, itemBuilder:(c,i){
            final p=_providers[i] as Map; final sel=p['id']==_selectedProvider;
            final type = p['type'] as String? ?? '';
            return GestureDetector(onTap:()=>setState(()=>_selectedProvider=p['id'] as String), child:Container(
              color: sel? const Color(0xFF2B2B31): Colors.transparent,
              padding:const EdgeInsets.symmetric(horizontal:10, vertical:10),
              child:Row(children:[
              Icon(_driverIcon(type), size:16, color: sel? Colors.white: const Color(0xFF9B9BA3)),
              const SizedBox(width:10),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start, children:[
                Text(p['name']??p['id'], style:TextStyle(fontSize:12, color: sel? Colors.white: const Color(0xFFD4D4D8), fontWeight: sel? FontWeight.w600: FontWeight.normal), overflow:TextOverflow.ellipsis, maxLines:1),
                const SizedBox(height:2),
                Row(children:[
                  Container(padding: const EdgeInsets.symmetric(horizontal:4, vertical:1), decoration: BoxDecoration(color: const Color(0xFF2A2A2E), borderRadius: BorderRadius.circular(3)), child: Text(_driverLabel(type), style: const TextStyle(fontSize:9, color: Color(0xFF9B9BA3)))),
                  const SizedBox(width:4),
                  Expanded(child: Text(p['remote_root']??'mods', style: const TextStyle(fontSize:9, color: Color(0xFF6E6E76)), overflow: TextOverflow.ellipsis)),
                ]),
              ])),
              const SizedBox(width:6),
              Tooltip(message: '测试连接', child: GestureDetector(onTap:()=>_test(p['id'] as String), child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(border: Border.all(color: const Color(0xFF2A2A2E)), borderRadius: BorderRadius.circular(4)), child: const Icon(FluentIcons.checkmark_24_regular, size:10, color:Color(0xFF6E6E76))))),
              const SizedBox(width:4),
              Tooltip(message: '编辑', child: GestureDetector(onTap:()=>_addProvider(editTarget: p), child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(border: Border.all(color: const Color(0xFF2A2A2E)), borderRadius: BorderRadius.circular(4)), child: const Icon(FluentIcons.edit_24_regular, size:10, color:Color(0xFF6E6E76))))),
              const SizedBox(width:4),
              Tooltip(message: '删除', child: GestureDetector(onTap:()=>_del(p['id'] as String), child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)), borderRadius: BorderRadius.circular(4)), child: const Icon(FluentIcons.delete_24_regular, size:10, color:Colors.redAccent)))),
            ])));
          })),
          if(_providers.isEmpty && !_loading) const Padding(padding:EdgeInsets.all(16), child:Column(children:[
            Icon(FluentIcons.cloud_24_regular, size:28, color: Color(0xFF3A3A3E)),
            SizedBox(height:8),
            Text('暂无云盘', style:TextStyle(fontSize:12, color:Color(0xFFD4D4D8))),
            SizedBox(height:4),
            Text('点击右上角 + 新增\n推荐：本地目录测试 → OpenList 代理', textAlign: TextAlign.center, style:TextStyle(fontSize:10, color:Color(0xFF6E6E76))),
          ])),
          // provider 状态 history
          if(_syncStatus!=null && (_syncStatus!['history'] as List?)?.isNotEmpty==true) Container(
            height: 70,
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF2A2A2E)))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
              const Text('最近同步', style: TextStyle(fontSize:10, color: Color(0xFF6E6E76))),
              const SizedBox(height:4),
              Expanded(child: ListView(
                children: ((_syncStatus!['history'] as List).take(3).map((h)=> Padding(
                  padding: const EdgeInsets.only(bottom:2),
                  child: Text('${h['time']} ${h['mod']} ${h['direction']} x${h['count']}', style: const TextStyle(fontSize:9, color: Color(0xFF8B8B93)), overflow: TextOverflow.ellipsis),
                )).toList()),
              )),
            ]),
          ),
        ]),
      );

      final localList = Expanded(
        child: Container(
          decoration: BoxDecoration(color: const Color(0xFF1E1E23), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFF2A2A2E))),
          child: Column(children:[
            Container(
              padding: const EdgeInsets.symmetric(horizontal:8, vertical:6),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF2A2A2E)))),
              child: Row(children:[
                const Icon(FluentIcons.folder_24_regular, size:12, color: Color(0xFF9B9BA3)),
                const SizedBox(width:6),
                Text('本地 ${_localFiles.length}', style: const TextStyle(fontSize:11, color: Color(0xFFD4D4D8), fontWeight: FontWeight.w600)),
                const Spacer(),
                Flexible(child: ConstrainedBox(constraints: BoxConstraints(maxWidth:110), child: fluent.TextBox(placeholder: '搜索', onChanged: (v)=>setState(()=>_localSearch=v), style: const TextStyle(fontSize:11)))),
                const SizedBox(width:6),
                Tooltip(message: '全选/全不选', child: fluent.Checkbox(checked: _checked.length==filteredLocal.length && filteredLocal.isNotEmpty, onChanged: (v){
                  setState((){
                    if(v==true) _checked.addAll(filteredLocal.map((e)=> e['name'] as String));
                    else _checked.clear();
                  });
                })),
              ]),
            ),
            Expanded(child: filteredLocal.isEmpty? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children:[
              const Icon(FluentIcons.document_24_regular, size:22, color: Color(0xFF3A3A3E)),
              const SizedBox(height:6),
              Text(_selectedMod==null? '请选择 Mod' : '暂无文件', style: const TextStyle(fontSize:11, color: Color(0xFF6E6E76))),
              if(_selectedMod!=null) Padding(padding: const EdgeInsets.only(top:4), child: Text('Mod: $_selectedMod', style: const TextStyle(fontSize:10, color: Color(0xFF8B8B93)))),
            ])) : ListView.builder(
              itemCount: filteredLocal.length,
              itemBuilder: (c,i){
                final e=filteredLocal[i] as Map;
                final name=e['name'] as String;
                final ck=_checked.contains(name);
                final sz = e['size'] as int? ?? 0;
                final szStr = sz>1024*1024 ? '${(sz/1024/1024).toStringAsFixed(1)} MB' : sz>1024 ? '${(sz/1024).toStringAsFixed(1)} KB' : '$sz B';
                return Container(
                  color: ck? const Color(0xFF2B2B31).withValues(alpha: 0.5) : Colors.transparent,
                  child: fluent.Checkbox(
                    checked: ck,
                    onChanged:(v)=>setState(()=> v==true? _checked.add(name): _checked.remove(name)),
                    content: Expanded(child: Row(children:[
                      Expanded(child: Text(name, style: const TextStyle(fontSize:11, color: Color(0xFFD4D4D8)), overflow:TextOverflow.ellipsis)),
                      const SizedBox(width:6),
                      Flexible(child: Text(szStr, maxLines:1, overflow:TextOverflow.ellipsis, style: const TextStyle(fontSize:9, color: Color(0xFF6E6E76)))),
                    ])),
                  ),
                );
              }
            )),
          ]),
        ),
      );

      final remoteList = Expanded(
        child: Container(
          decoration: BoxDecoration(color: const Color(0xFF1E1E23), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFF2A2A2E))),
          child: Column(children:[
            Container(
              padding: const EdgeInsets.symmetric(horizontal:8, vertical:6),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF2A2A2E)))),
              child: Row(children:[
                const Icon(FluentIcons.cloud_24_regular, size:12, color: Color(0xFF9B9BA3)),
                const SizedBox(width:6),
                Flexible(child: Text('远端 ${_remoteFiles.length}', maxLines:1, overflow:TextOverflow.ellipsis, style: const TextStyle(fontSize:11, color: Color(0xFFD4D4D8), fontWeight: FontWeight.w600))),
                const Spacer(),
                if(_loadingRemote) const SizedBox(width:12, height:12, child: fluent.ProgressRing(strokeWidth:2)),
                const SizedBox(width:6),
                fluent.Button(onPressed: _loadRemote, child: const Text('刷新', style: TextStyle(fontSize:11))),
              ]),
            ),
            Expanded(child: _remoteFiles.isEmpty? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children:[
              const Icon(FluentIcons.cloud_24_regular, size:22, color: Color(0xFF3A3A3E)),
              const SizedBox(height:6),
              Text(_selectedProvider==null ? '请选择云盘' : _selectedMod==null ? '请选择 Mod' : '远端为空或未同步', style: const TextStyle(fontSize:11, color: Color(0xFF6E6E76))),
              if(_selectedProvider!=null && _selectedMod!=null) const Padding(padding: EdgeInsets.only(top:4), child: Text('点击上传可创建远端目录', style: TextStyle(fontSize:10, color: Color(0xFF8B8B93)))),
            ])) : ListView.builder(
              itemCount: _remoteFiles.length,
              itemBuilder: (c,i){
                final e=_remoteFiles[i] as Map;
                final name = e['name'] as String? ?? e['path'] as String? ?? '';
                final isDir = e['is_dir']==true;
                final sz = e['size'] as int? ?? 0;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal:10, vertical:6),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: const Color(0xFF2A2A2E).withValues(alpha: 0.5)))),
                  child: Row(children:[
                    Icon(isDir? FluentIcons.folder_24_regular : FluentIcons.document_24_regular, size:12, color: isDir? const Color(0xFFF2C25C): const Color(0xFF9B9BA3)),
                    const SizedBox(width:8),
                    Expanded(child: Text(name, style: const TextStyle(fontSize:11, color: Color(0xFFD4D4D8)), overflow: TextOverflow.ellipsis)),
                    if(!isDir) Text(sz>1024? '${(sz/1024).toStringAsFixed(1)}KB':'$sz B', style: const TextStyle(fontSize:9, color: Color(0xFF6E6E76))),
                  ]),
                );
              }
            )),
          ]),
        ),
      );

      final syncPane = SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment:CrossAxisAlignment.stretch, children:[
          _buildRealtimePanel(),
          // Mod 选择
          Row(children:[
            Expanded(child: fluent.ComboBox<String>(
              value:_selectedMod,
              placeholder:const Text('选择 Mod', style:TextStyle(fontSize:11)),
              isExpanded:true,
              items:mods.map((m)=>fluent.ComboBoxItem(value:m.name, child: Row(children:[
                const Icon(FluentIcons.apps_24_regular, size:12, color: Color(0xFF9B9BA3)),
                const SizedBox(width:6),
                Expanded(child: Text(m.name, overflow:TextOverflow.ellipsis, style:const TextStyle(fontSize:11))),
                Text('${m.cfgFiles.length} 配置', style: const TextStyle(fontSize:9, color: Color(0xFF6E6E76))),
              ]))).toList(),
              onChanged:(v){ setState(()=>_selectedMod=v); _loadFiles(); }
            )),
            const SizedBox(width:8),
            Tooltip(message: '刷新本地与远端', child: fluent.Button(onPressed:_loadFiles, child: Row(mainAxisSize: MainAxisSize.min, children: const [Icon(FluentIcons.arrow_sync_24_regular, size:12), SizedBox(width:4), Text('刷新', style:TextStyle(fontSize:11))]))),
          ]),
          const SizedBox(height:10),
          // 方向与选项
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF1A1A1E), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF2A2A2E))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
              Row(children:[
                const Text('方向', style: TextStyle(fontSize:11, color: Color(0xFF9B9BA3))),
                const SizedBox(width:12),
                Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children:[
                  _directionChip('upload', '上传', FluentIcons.arrow_upload_24_regular),
                  const SizedBox(width:6),
                  _directionChip('download', '下载', FluentIcons.arrow_download_24_regular),
                  const SizedBox(width:6),
                  _directionChip('sync', '双向', FluentIcons.arrow_sync_24_regular),
                ])),
                ),
              ]),
              const SizedBox(height:10),
              Wrap(spacing:12, runSpacing:8, crossAxisAlignment: WrapCrossAlignment.center, children:[
                Row(mainAxisSize: MainAxisSize.min, children:[
                  fluent.Checkbox(checked:_dryRun, onChanged:(v)=>setState(()=>_dryRun=v??false)),
                  const SizedBox(width:4),
                  Tooltip(message: '仅预览变更，不实际上传/下载', child: const Text('DryRun 预览', style:TextStyle(fontSize:11))),
                ]),
                if(_direction=='upload') Row(mainAxisSize: MainAxisSize.min, children:[
                  fluent.Checkbox(checked:_deleteExtra, onChanged:(v)=>setState(()=>_deleteExtra=v??false)),
                  const SizedBox(width:4),
                  Tooltip(message: '删除远端多余文件（危险）', child: const Text('清理远端多余', style:TextStyle(fontSize:11))),
                ]),
                const SizedBox(width:8),
                fluent.FilledButton(
                  onPressed: _busy ? null : _syncFolder,
                  child: Row(mainAxisSize: MainAxisSize.min, children:[
                    if(_busy) const SizedBox(width:12, height:12, child: fluent.ProgressRing(strokeWidth:2)),
                    if(_busy) const SizedBox(width:6),
                    Text(_busy? '同步中...': (_dryRun? '预览整Mod':'同步整Mod'), style: const TextStyle(fontSize:11)),
                  ]),
                ),
              ]),
              const SizedBox(height:8),
              Text(
                _direction=='upload' ? '上传：本地 → 远端（覆盖同名，跳过未变更）' :
                _direction=='download' ? '下载：远端 → 本地（增量，本地多余文件保留）' :
                '双向：以 mtime 新者为准，冲突时本地优先。远端无 mtime 时以本地为准',
                style: const TextStyle(fontSize:10, color: Color(0xFF6E6E76)),
              ),
            ]),
          ),
          _buildProgress(),
          const SizedBox(height:10),
          // 文件对比区
          Row(children:[
            const Text('文件对比', style:TextStyle(fontSize:12, color:Color(0xFFD4D4D8), fontWeight:FontWeight.w600)),
            const SizedBox(width:8),
            Text('已选 ${_checked.length}/${filteredLocal.length}', style: const TextStyle(fontSize:10, color: Color(0xFF8B8B93))),
            const Spacer(),
            fluent.Button(onPressed:_busy? null : _syncFiles, child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(FluentIcons.document_multiple_24_regular, size:12), const SizedBox(width:4), Text(_dryRun? '预览选中':'同步选中 (${_checked.length})', style: const TextStyle(fontSize:11))])) ,
          ]),
          const SizedBox(height:8),
          SizedBox(height: 320, width: double.infinity, child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children:[
            localList,
            const SizedBox(width:10),
            remoteList,
          ])),
          _buildResult(),
        ]),
      );
      return Column(children:[
        Container(height:44, padding:const EdgeInsets.symmetric(horizontal:12), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF2A2A2E)))), child:Row(children:[
          const Icon(FluentIcons.cloud_sync_24_regular, size:16, color: Color(0xFF4F6EF7)),
          const SizedBox(width:8),
          Flexible(child: Text('云同步 · 整Mod文件夹', maxLines:1, overflow:TextOverflow.ellipsis, style:TextStyle(fontSize:13, color:Color(0xFFD4D4D8), fontWeight:FontWeight.w600))),
          const SizedBox(width:8),
          Flexible(child: Container(padding: const EdgeInsets.symmetric(horizontal:6, vertical:2), decoration: BoxDecoration(color: const Color(0xFF1E1E23), borderRadius: BorderRadius.circular(4)), child: Text('增量 · mtime+size+sha1 · 双向', maxLines:1, overflow:TextOverflow.ellipsis, style: TextStyle(fontSize:9, color: Color(0xFF8B8B93))))),
          const Spacer(),
          if(_selectedProvider!=null) Flexible(child: Container(padding: const EdgeInsets.symmetric(horizontal:8, vertical:4), decoration: BoxDecoration(color: const Color(0xFF2B2B31), borderRadius: BorderRadius.circular(4)), child: Row(mainAxisSize: MainAxisSize.min, children:[
            Icon(_driverIcon(_providers.firstWhere((p)=>p['id']==_selectedProvider, orElse:()=>{'type':'local'})['type']), size:12, color: const Color(0xFF9B9BA3)),
            const SizedBox(width:4),
            Flexible(child: Text(_providers.firstWhere((p)=>p['id']==_selectedProvider, orElse:()=>{'name':'?'})['name'], maxLines:1, overflow:TextOverflow.ellipsis, style: const TextStyle(fontSize:11, color: Color(0xFFD4D4D8)))),
          ]))),
        ])),
        Expanded(child: narrow
          ? Column(children:[SizedBox(height: 320, child: providerPane), const Divider(height:1, color:Color(0xFF2A2A2E)), Expanded(child: syncPane)])
          : Row(crossAxisAlignment:CrossAxisAlignment.stretch, children:[SizedBox(width:280, child: providerPane), const VerticalDivider(width:1, color:Color(0xFF2A2A2E)), Expanded(child: syncPane)])),
      ]);
    });
  }
}
