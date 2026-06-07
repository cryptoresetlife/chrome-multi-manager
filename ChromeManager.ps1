Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Data, Microsoft.VisualBasic

Add-Type @"
using System; using System.Runtime.InteropServices;
public class WinAPI2 {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr i,int x,int y,int w,int h2,uint f);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
}
"@
Add-Type @"
using System; using System.Net.WebSockets; using System.Threading; using System.Text;
public class CDP2 {
    public static string Send(string ws, string json) {
        try {
            using (var c = new ClientWebSocket()) {
                c.ConnectAsync(new Uri(ws), CancellationToken.None).GetAwaiter().GetResult();
                var b = Encoding.UTF8.GetBytes(json);
                c.SendAsync(new ArraySegment<byte>(b), WebSocketMessageType.Text, true, CancellationToken.None).GetAwaiter().GetResult();
                var buf = new byte[32768];
                var r = c.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None).GetAwaiter().GetResult();
                try { c.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None).GetAwaiter().GetResult(); } catch {}
                return Encoding.UTF8.GetString(buf, 0, r.Count);
            }
        } catch (Exception ex) { return "err:" + ex.Message; }
    }
}
"@

Add-Type @"
using System; using System.Collections.Concurrent; using System.Collections.Generic;
using System.IO; using System.Net; using System.Net.WebSockets;
using System.Runtime.InteropServices; using System.Text;
using System.Text.RegularExpressions; using System.Threading;
public class MouseSync {
    public const int WH_MOUSE_LL=14,WH_KEYBOARD_LL=13,
        WM_MOUSEMOVE=0x200,WM_LBUTTONDOWN=0x201,WM_LBUTTONUP=0x202,WM_RBUTTONDOWN=0x204,WM_RBUTTONUP=0x205,
        WM_MOUSEWHEEL=0x20A,WM_LBUTTONDBLCLK=0x203,WM_KEYDOWN=0x100,WM_KEYUP=0x101,WM_CHAR=0x102,
        WM_SYSKEYDOWN=0x104,WM_SYSKEYUP=0x105,WM_SYSCHAR=0x106,WM_QUIT=0x12;
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id,HookProc fn,IntPtr mod,uint tid);
    [DllImport("user32.dll",SetLastError=true)] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h,int n,IntPtr w,IntPtr l);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string s);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out RECT r);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h,ref POINT p);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref POINT p);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg,IntPtr h,uint min,uint max);
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg,IntPtr h,uint min,uint max,uint remove);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint id,uint msg,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern short GetKeyState(int vk);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWinProc fn,IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    delegate bool EnumWinProc(IntPtr h,IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct POINT{public int x,y;}
    [StructLayout(LayoutKind.Sequential)] public struct RECT{public int L,T,R,B;}
    [StructLayout(LayoutKind.Sequential)] struct MSG{public IntPtr hwnd;public uint message;public IntPtr wParam;public IntPtr lParam;public uint time;public POINT pt;}
    [StructLayout(LayoutKind.Sequential)] struct MSLL{public POINT pt;public uint d,f,t;public IntPtr e;}
    [StructLayout(LayoutKind.Sequential)] struct KBDLL{public uint vk,sc,flags,t;public IntPtr e;}
    public delegate IntPtr HookProc(int n,IntPtr w,IntPtr l);
    static IntPtr _mhook,_khook; static HookProc _mproc,_kproc;
    public static IntPtr MasterHwnd=IntPtr.Zero;
    public static int MasterPid=0;
    public static int TopOffset=88;
    public static int LastMouseHookError=0,LastKeyboardHookError=0;
    public struct Evt{public int Type,Px,Py,WinPx,WinPy,Btn,Delta,Modifiers,InPage;}
    public struct KbdEvt{public int Msg,VK,SC,Flags,Modifiers;}
    static ConcurrentQueue<Evt> _q=new ConcurrentQueue<Evt>();
    static ConcurrentQueue<KbdEvt> _kq=new ConcurrentQueue<KbdEvt>();
    static int _lastMx=-1,_lastMy=-1;

    public static IntPtr FindChromeWindow(int pid){
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,l)=>{
            uint wp; GetWindowThreadProcessId(h,out wp);
            if((int)wp==pid&&IsWindowVisible(h)&&GetWindowTextLength(h)>0){found=h;return false;}
            return true;
        },IntPtr.Zero);
        return found;
    }

    public static int CalcTopOffset(string wsUrl,IntPtr hwnd){
        try{
            RECT wr; if(!GetWindowRect(hwnd,out wr))return 88;
            using(var c=new ClientWebSocket()){
                c.ConnectAsync(new Uri(wsUrl),CancellationToken.None).GetAwaiter().GetResult();
                var b=Encoding.UTF8.GetBytes("{\"id\":99,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"window.screenY\"}}");
                c.SendAsync(new ArraySegment<byte>(b),WebSocketMessageType.Text,true,CancellationToken.None).GetAwaiter().GetResult();
                var buf=new byte[4096];
                var r=c.ReceiveAsync(new ArraySegment<byte>(buf),CancellationToken.None).GetAwaiter().GetResult();
                try{c.CloseAsync(WebSocketCloseStatus.NormalClosure,"",CancellationToken.None).GetAwaiter().GetResult();}catch{}
                var m=Regex.Match(Encoding.UTF8.GetString(buf,0,r.Count),@"""value""\s*:\s*(\d+)");
                if(m.Success){int off=int.Parse(m.Groups[1].Value)-wr.T;return(off>0&&off<300)?off:88;}
            }
        }catch{}return 88;
    }

    static int CurrentModifiers(){
        int m=0;
        if((GetKeyState(0x12)&0x8000)!=0)m|=1; // Alt
        if((GetKeyState(0x11)&0x8000)!=0)m|=2; // Ctrl
        if((GetKeyState(0x5B)&0x8000)!=0||(GetKeyState(0x5C)&0x8000)!=0)m|=4; // Win/Meta
        if((GetKeyState(0x10)&0x8000)!=0)m|=8; // Shift
        return m;
    }
    static object _hookLock=new object();
    static Thread _hookThread; static uint _hookThreadId;
    static bool _wantMouse,_wantKbd;
    static ManualResetEvent _hookReady;

    public static bool StartHook(){lock(_hookLock){_wantMouse=true;return RestartHookThread();}}
    public static void StopHook(){lock(_hookLock){_wantMouse=false;if(_wantKbd)RestartHookThread();else StopHookThread();}}
    public static bool StartKbdHook(){lock(_hookLock){_wantKbd=true;return RestartHookThread();}}
    public static void StopKbdHook(){lock(_hookLock){_wantKbd=false;if(_wantMouse)RestartHookThread();else StopHookThread();}}

    static bool RestartHookThread(){
        StopHookThread();
        LastMouseHookError=0;LastKeyboardHookError=0;
        if(!_wantMouse&&!_wantKbd)return true;
        _hookReady=new ManualResetEvent(false);
        _hookThread=new Thread(HookLoop);
        _hookThread.IsBackground=true;
        _hookThread.Name="ChromeManagerInputHook";
        _hookThread.Start();
        if(!_hookReady.WaitOne(3000))return false;
        return (!_wantMouse||_mhook!=IntPtr.Zero)&&(!_wantKbd||_khook!=IntPtr.Zero);
    }
    static void StopHookThread(){
        if(_hookThread!=null&&_hookThread.IsAlive){
            if(_hookThreadId!=0)PostThreadMessage(_hookThreadId,(uint)WM_QUIT,IntPtr.Zero,IntPtr.Zero);
            if(!_hookThread.Join(1200))PostThreadMessage(_hookThreadId,(uint)WM_QUIT,IntPtr.Zero,IntPtr.Zero);
        }
        _hookThread=null;_hookThreadId=0;
    }
    static void HookLoop(){
        MSG msg;
        _hookThreadId=GetCurrentThreadId();
        PeekMessage(out msg,IntPtr.Zero,0,0,0);
        try{
            _mproc=CB;_kproc=KbdCB;
            if(_wantMouse){
                _mhook=SetWindowsHookEx(WH_MOUSE_LL,_mproc,GetModuleHandle(null),0);
                if(_mhook==IntPtr.Zero){
                    LastMouseHookError=Marshal.GetLastWin32Error();
                    _mhook=SetWindowsHookEx(WH_MOUSE_LL,_mproc,IntPtr.Zero,0);
                    if(_mhook==IntPtr.Zero)LastMouseHookError=Marshal.GetLastWin32Error();
                }
            }
            if(_wantKbd){
                _khook=SetWindowsHookEx(WH_KEYBOARD_LL,_kproc,GetModuleHandle(null),0);
                if(_khook==IntPtr.Zero){
                    LastKeyboardHookError=Marshal.GetLastWin32Error();
                    _khook=SetWindowsHookEx(WH_KEYBOARD_LL,_kproc,IntPtr.Zero,0);
                    if(_khook==IntPtr.Zero)LastKeyboardHookError=Marshal.GetLastWin32Error();
                }
            }
        }finally{
            if(_hookReady!=null)_hookReady.Set();
        }
        try{while(GetMessage(out msg,IntPtr.Zero,0,0)>0){}}
        finally{
            if(_mhook!=IntPtr.Zero){UnhookWindowsHookEx(_mhook);_mhook=IntPtr.Zero;}
            if(_khook!=IntPtr.Zero){UnhookWindowsHookEx(_khook);_khook=IntPtr.Zero;}
        }
    }
    static IntPtr CB(int n,IntPtr w,IntPtr l){
        if(n>=0&&MasterHwnd!=IntPtr.Zero){
            var ms=(MSLL)Marshal.PtrToStructure(l,typeof(MSLL));
            RECT r,cr; int t=w.ToInt32();
            if(GetWindowRect(MasterHwnd,out r)&&GetClientRect(MasterHwnd,out cr)){
                POINT cp=new POINT{x=ms.pt.x,y=ms.pt.y};
                ScreenToClient(MasterHwnd,ref cp);
                int clientW=cr.R-cr.L,clientH=cr.B-cr.T;
                if(cp.x>=0&&cp.x<=clientW&&cp.y>=0&&cp.y<=clientH&&clientW>0&&clientH>0){
                    int winPx=cp.x*10000/clientW,winPy=cp.y*10000/clientH;
                    int cx=r.L,cy=r.T+TopOffset,cw=r.R-r.L,ch=r.B-r.T-TopOffset;
                    int px=0,py=0,inPage=0;
                    if(ms.pt.x>=cx&&ms.pt.x<=r.R&&ms.pt.y>=cy&&ms.pt.y<=r.B&&cw>0&&ch>0){
                        px=(ms.pt.x-cx)*10000/cw;py=(ms.pt.y-cy)*10000/ch;inPage=1;
                    }
                    int mod=CurrentModifiers();
                    if(t==WM_MOUSEMOVE){
                        if(Math.Abs(winPx-_lastMx)>=20||Math.Abs(winPy-_lastMy)>=20){
                            _lastMx=winPx;_lastMy=winPy;
                            _q.Enqueue(new Evt{Type=t,Px=px,Py=py,WinPx=winPx,WinPy=winPy,Modifiers=mod,InPage=inPage});
                        }
                    }else if(t==WM_LBUTTONDOWN||t==WM_LBUTTONUP||t==WM_RBUTTONDOWN||t==WM_RBUTTONUP||t==WM_MOUSEWHEEL||t==WM_LBUTTONDBLCLK){
                        _q.Enqueue(new Evt{Type=t,Px=px,Py=py,WinPx=winPx,WinPy=winPy,
                            Btn=(t==WM_LBUTTONDOWN||t==WM_LBUTTONUP||t==WM_LBUTTONDBLCLK)?0:1,
                            Delta=(t==WM_MOUSEWHEEL)?(int)((short)(ms.d>>16)):0,
                            Modifiers=mod,InPage=inPage});
                    }
                }
            }
        }
        return CallNextHookEx(_mhook,n,w,l);
    }
    static IntPtr KbdCB(int n,IntPtr w,IntPtr l){
        if(n>=0&&MasterPid>0){
            uint fp; GetWindowThreadProcessId(GetForegroundWindow(),out fp);
            if((int)fp==MasterPid){
                var kb=(KBDLL)Marshal.PtrToStructure(l,typeof(KBDLL));
                int msg=w.ToInt32();
                if(msg==WM_KEYDOWN||msg==WM_SYSKEYDOWN||msg==WM_KEYUP||msg==WM_SYSKEYUP)
                    _kq.Enqueue(new KbdEvt{Msg=msg,VK=(int)kb.vk,SC=(int)kb.sc,Flags=(int)kb.flags,Modifiers=CurrentModifiers()});
            }
        }
        return CallNextHookEx(_khook,n,w,l);
    }
    static volatile bool _ra; static Thread _rt;
    static int[] _slaves=new int[0];
    static IntPtr[] _slaveWindows=new IntPtr[0];
    static Dictionary<int,string> _wsUrl=new Dictionary<int,string>();
    static Dictionary<int,int[]> _vp=new Dictionary<int,int[]>();
    static Dictionary<int,ClientWebSocket> _wsCon=new Dictionary<int,ClientWebSocket>();
    public static void StartRelay(int[] ports){StartRelay(ports,null);}
    public static void StartRelay(int[] ports,IntPtr[] hwnds){
        var clean=new List<int>();var wins=new List<IntPtr>();var seen=new HashSet<int>();
        if(ports!=null)for(int i=0;i<ports.Length;i++){
            var p=ports[i];
            if(p>0&&seen.Add(p)){
                clean.Add(p);
                wins.Add((hwnds!=null&&i<hwnds.Length)?hwnds[i]:IntPtr.Zero);
            }
        }
        _slaves=clean.ToArray(); _slaveWindows=wins.ToArray(); _wsUrl.Clear(); _vp.Clear();
        foreach(var c in _wsCon.Values){try{c.Dispose();}catch{}} _wsCon.Clear();
        _ra=true; _rt=new Thread(Relay){IsBackground=true}; _rt.Start();
    }
    public static void StopAll(){lock(_hookLock){_wantMouse=false;_wantKbd=false;StopHookThread();}_ra=false;}
    static string GetWsUrl(int port){
        try{
            var req=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:"+port+"/json");
            req.Timeout=1500;
            using(var rs=req.GetResponse())using(var sr=new StreamReader(rs.GetResponseStream())){
                var j=sr.ReadToEnd();
                foreach(Match o in Regex.Matches(j,@"\{[^{}]*\}")){
                    if(o.Value.Contains("\"page\"")){
                        var m=Regex.Match(o.Value,@"""webSocketDebuggerUrl""\s*:\s*""([^""]+)""");
                        if(m.Success)return m.Groups[1].Value;
                    }
                }
            }
        }catch{}return null;
    }
    static int[] QueryVp(string url){
        try{
            using(var c=new ClientWebSocket()){
                c.ConnectAsync(new Uri(url),CancellationToken.None).GetAwaiter().GetResult();
                var b=Encoding.UTF8.GetBytes("{\"id\":8,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"window.innerWidth+','+window.innerHeight\"}}");
                c.SendAsync(new ArraySegment<byte>(b),WebSocketMessageType.Text,true,CancellationToken.None).GetAwaiter().GetResult();
                var buf=new byte[4096];
                var r=c.ReceiveAsync(new ArraySegment<byte>(buf),CancellationToken.None).GetAwaiter().GetResult();
                try{c.CloseAsync(WebSocketCloseStatus.NormalClosure,"",CancellationToken.None).GetAwaiter().GetResult();}catch{}
                var m=Regex.Match(Encoding.UTF8.GetString(buf,0,r.Count),"\"value\"\\s*:\\s*\"(\\d+),(\\d+)\"");
                if(m.Success)return new[]{int.Parse(m.Groups[1].Value),int.Parse(m.Groups[2].Value)};
            }
        }catch{}return new[]{1280,800};
    }
    static ClientWebSocket EnsureConn(int port){
        ClientWebSocket c;
        if(_wsCon.TryGetValue(port,out c)&&c!=null&&c.State==WebSocketState.Open)return c;
        string url;
        if(!_wsUrl.TryGetValue(port,out url)||url==null){
            url=GetWsUrl(port);if(url==null)return null;_wsUrl[port]=url;
        }
        try{
            if(c!=null){try{c.Dispose();}catch{}}
            c=new ClientWebSocket();
            c.ConnectAsync(new Uri(url),CancellationToken.None).GetAwaiter().GetResult();
            _wsCon[port]=c;
            var cc=c;
            new Thread(()=>{var buf=new byte[4096];try{while(cc.State==WebSocketState.Open)cc.ReceiveAsync(new ArraySegment<byte>(buf),CancellationToken.None).GetAwaiter().GetResult();}catch{}}){IsBackground=true}.Start();
            return c;
        }catch{return null;}
    }
    static void Drop(int port){
        if(_wsCon.ContainsKey(port)){try{_wsCon[port].Dispose();}catch{}_wsCon.Remove(port);}
        _wsUrl.Remove(port);_vp.Remove(port);
    }
    static void Send(ClientWebSocket ws,string json){
        var b=Encoding.UTF8.GetBytes(json);
        ws.SendAsync(new ArraySegment<byte>(b),WebSocketMessageType.Text,true,CancellationToken.None).GetAwaiter().GetResult();
    }
    static int _msgId=10;
    static int NextId(){return Interlocked.Increment(ref _msgId);}
    static IntPtr MakeLParam(int x,int y){return (IntPtr)unchecked((int)(((y&0xffff)<<16)|(x&0xffff)));}
    static IntPtr MakeKeyLParam(int sc,bool up,bool extended){
        int v=1|((sc&0xff)<<16);
        if(extended)v|=1<<24;
        if(up)v|=(1<<30)|(1<<31);
        return (IntPtr)v;
    }
    static int MouseKeyState(int modifiers){
        int w=0;
        if((modifiers&8)!=0)w|=0x0004;
        if((modifiers&2)!=0)w|=0x0008;
        return w;
    }
    static string JsonEscape(string s){
        if(s==null)return"";
        return s.Replace("\\","\\\\").Replace("\"","\\\"").Replace("\r","\\r").Replace("\n","\\n").Replace("\t","\\t");
    }
    static bool DispatchWinMouse(IntPtr hwnd,Evt e){
        if(hwnd==IntPtr.Zero||!IsWindow(hwnd))return false;
        RECT cr;if(!GetClientRect(hwnd,out cr))return false;
        int cw=cr.R-cr.L,ch=cr.B-cr.T;if(cw<=0||ch<=0)return false;
        int x=Math.Max(0,Math.Min(cw-1,e.WinPx*cw/10000));
        int y=Math.Max(0,Math.Min(ch-1,e.WinPy*ch/10000));
        int w=MouseKeyState(e.Modifiers);
        uint msg;
        if(e.Type==WM_MOUSEMOVE)msg=WM_MOUSEMOVE;
        else if(e.Type==WM_LBUTTONDOWN){msg=WM_LBUTTONDOWN;w|=0x0001;}
        else if(e.Type==WM_LBUTTONUP)msg=WM_LBUTTONUP;
        else if(e.Type==WM_RBUTTONDOWN){msg=WM_RBUTTONDOWN;w|=0x0002;}
        else if(e.Type==WM_RBUTTONUP)msg=WM_RBUTTONUP;
        else if(e.Type==WM_LBUTTONDBLCLK){PostMessage(hwnd,(uint)WM_LBUTTONDBLCLK,(IntPtr)(w|0x0001),MakeLParam(x,y));PostMessage(hwnd,(uint)WM_LBUTTONUP,(IntPtr)w,MakeLParam(x,y));return true;}
        else if(e.Type==WM_MOUSEWHEEL){
            POINT sp=new POINT{x=x,y=y};ClientToScreen(hwnd,ref sp);
            int wp=unchecked((int)(((e.Delta&0xffff)<<16)|(w&0xffff)));
            PostMessage(hwnd,(uint)WM_MOUSEWHEEL,(IntPtr)wp,MakeLParam(sp.x,sp.y));
            return true;
        }else return false;
        PostMessage(hwnd,msg,(IntPtr)w,MakeLParam(x,y));
        return true;
    }
    static void Dispatch(ClientWebSocket ws,Evt e,int x,int y){
        string btn=e.Btn==1?"right":"left",j;
        int buttons=e.Btn==1?2:1;
        string common=",\"x\":"+x+",\"y\":"+y+",\"modifiers\":"+e.Modifiers;
        if(e.Type==WM_MOUSEMOVE)
            j="{\"id\":"+NextId()+",\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mouseMoved\",\"button\":\"none\""+common+"}}";
        else if(e.Type==WM_LBUTTONDOWN||e.Type==WM_RBUTTONDOWN)
            j="{\"id\":"+NextId()+",\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mousePressed\",\"button\":\""+btn+"\",\"buttons\":"+buttons+",\"clickCount\":1"+common+"}}";
        else if(e.Type==WM_LBUTTONUP||e.Type==WM_RBUTTONUP)
            j="{\"id\":"+NextId()+",\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mouseReleased\",\"button\":\""+btn+"\",\"buttons\":0,\"clickCount\":1"+common+"}}";
        else if(e.Type==WM_LBUTTONDBLCLK){
            j="{\"id\":"+NextId()+",\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mousePressed\",\"button\":\"left\",\"buttons\":1,\"clickCount\":2"+common+"}}";
            Send(ws,j);
            j="{\"id\":"+NextId()+",\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mouseReleased\",\"button\":\"left\",\"buttons\":0,\"clickCount\":2"+common+"}}";
        }
        else if(e.Type==WM_MOUSEWHEEL)
            j="{\"id\":"+NextId()+",\"method\":\"Input.dispatchMouseEvent\",\"params\":{\"type\":\"mouseWheel\",\"deltaX\":0,\"deltaY\":"+(-e.Delta)+common+"}}";
        else return;
        Send(ws,j);
    }
    static string PrintableText(int vk,int modifiers){
        bool shift=(modifiers&8)!=0;
        bool caps=(GetKeyState(0x14)&1)!=0;
        bool upper=shift^caps;
        if(vk>=0x30&&vk<=0x39){if(shift){var s="!@#$%^&*()";return s[vk-0x30].ToString();}return((char)vk).ToString();}
        if(vk>=0x41&&vk<=0x5A)return(upper?(char)vk:(char)(vk+32)).ToString();
        if(vk>=0x60&&vk<=0x69)return(vk-0x60).ToString();
        switch(vk){
            case 0x20:return" ";
            case 0xBB:return shift?"+":"=";case 0xBD:return shift?"_":"-";
            case 0xBC:return shift?"<":",";case 0xBE:return shift?">":".";
            case 0xBF:return shift?"?":"/";case 0xC0:return shift?"~":"`";
            case 0xDB:return shift?"{":"[";case 0xDD:return shift?"}":"]";
            case 0xDC:return shift?"|":"\\";case 0xDE:return shift?"\"":"'";
            case 0xBA:return shift?":":";";case 0x6A:return"*";case 0x6B:return"+";
            case 0x6D:return"-";case 0x6E:return".";case 0x6F:return"/";
            default:return"";
        }
    }
    static string VkToKey(int vk,int modifiers){
        string text=PrintableText(vk,modifiers);
        if(text.Length>0)return text==" "?" ":text;
        if(vk>=0x70&&vk<=0x87)return"F"+(vk-0x6F);
        switch(vk){
            case 0x10:case 0xA0:case 0xA1:return"Shift";
            case 0x11:case 0xA2:case 0xA3:return"Control";
            case 0x12:case 0xA4:case 0xA5:return"Alt";
            case 0x5B:case 0x5C:return"Meta";
            case 0x08:return"Backspace";case 0x09:return"Tab";case 0x0D:return"Enter";
            case 0x1B:return"Escape";case 0x20:return"Space";case 0x25:return"ArrowLeft";
            case 0x26:return"ArrowUp";case 0x27:return"ArrowRight";case 0x28:return"ArrowDown";
            case 0x2E:return"Delete";case 0x2D:return"Insert";case 0x24:return"Home";
            case 0x23:return"End";case 0x21:return"PageUp";case 0x22:return"PageDown";
            default:return"";
        }
    }
    static string VkToCode(int vk){
        if(vk>=0x41&&vk<=0x5A)return"Key"+((char)vk);
        if(vk>=0x30&&vk<=0x39)return"Digit"+((char)vk);
        if(vk>=0x60&&vk<=0x69)return"Numpad"+(vk-0x60);
        if(vk>=0x70&&vk<=0x87)return"F"+(vk-0x6F);
        switch(vk){
            case 0x08:return"Backspace";case 0x09:return"Tab";case 0x0D:return"Enter";
            case 0x10:case 0xA0:return"ShiftLeft";case 0xA1:return"ShiftRight";
            case 0x11:case 0xA2:return"ControlLeft";case 0xA3:return"ControlRight";
            case 0x12:case 0xA4:return"AltLeft";case 0xA5:return"AltRight";
            case 0x5B:return"MetaLeft";case 0x5C:return"MetaRight";
            case 0x1B:return"Escape";case 0x20:return"Space";case 0x25:return"ArrowLeft";
            case 0x26:return"ArrowUp";case 0x27:return"ArrowRight";case 0x28:return"ArrowDown";
            case 0x2E:return"Delete";case 0x2D:return"Insert";case 0x24:return"Home";
            case 0x23:return"End";case 0x21:return"PageUp";case 0x22:return"PageDown";
            case 0xBB:return"Equal";case 0xBD:return"Minus";case 0xBC:return"Comma";
            case 0xBE:return"Period";case 0xBF:return"Slash";case 0xC0:return"Backquote";
            case 0xDB:return"BracketLeft";case 0xDD:return"BracketRight";case 0xDC:return"Backslash";
            case 0xDE:return"Quote";case 0xBA:return"Semicolon";case 0x6A:return"NumpadMultiply";
            case 0x6B:return"NumpadAdd";case 0x6D:return"NumpadSubtract";case 0x6E:return"NumpadDecimal";
            case 0x6F:return"NumpadDivide";default:return"";
        }
    }
    static int KeyLocation(int vk){
        if(vk>=0x60&&vk<=0x6F)return 3;
        if(vk==0xA0||vk==0xA2||vk==0xA4||vk==0x5B)return 1;
        if(vk==0xA1||vk==0xA3||vk==0xA5||vk==0x5C)return 2;
        return 0;
    }
    static bool DispatchWinKey(IntPtr hwnd,KbdEvt ke){
        if(hwnd==IntPtr.Zero||!IsWindow(hwnd))return false;
        bool down=ke.Msg==WM_KEYDOWN||ke.Msg==WM_SYSKEYDOWN;
        bool up=ke.Msg==WM_KEYUP||ke.Msg==WM_SYSKEYUP;
        if(!down&&!up)return false;
        bool alt=(ke.Modifiers&1)!=0;
        bool hasCommandModifier=(ke.Modifiers&(1|2|4))!=0;
        string text=PrintableText(ke.VK,ke.Modifiers);
        if(down&&text.Length>0&&!hasCommandModifier){
            foreach(char ch in text)PostMessage(hwnd,(uint)WM_CHAR,(IntPtr)ch,MakeKeyLParam(ke.SC,false,(ke.Flags&1)!=0));
            return true;
        }
        uint msg;
        if(down)msg=alt?(uint)WM_SYSKEYDOWN:(uint)WM_KEYDOWN;
        else msg=alt?(uint)WM_SYSKEYUP:(uint)WM_KEYUP;
        PostMessage(hwnd,msg,(IntPtr)ke.VK,MakeKeyLParam(ke.SC,up,(ke.Flags&1)!=0));
        return true;
    }
    static void DispatchKey(ClientWebSocket ws,KbdEvt ke){
        bool down=ke.Msg==WM_KEYDOWN||ke.Msg==WM_SYSKEYDOWN;
        string key=VkToKey(ke.VK,ke.Modifiers);
        if(string.IsNullOrEmpty(key))return;
        string code=VkToCode(ke.VK);
        if(string.IsNullOrEmpty(code))code=key;
        string sys=(ke.Msg==WM_SYSKEYDOWN||ke.Msg==WM_SYSKEYUP)?",\"isSystemKey\":true":"";
        string j="{\"id\":"+NextId()+",\"method\":\"Input.dispatchKeyEvent\",\"params\":{\"type\":\""+(down?"keyDown":"keyUp")+"\",\"windowsVirtualKeyCode\":"+ke.VK+",\"nativeVirtualKeyCode\":"+ke.VK+",\"key\":\""+JsonEscape(key)+"\",\"code\":\""+JsonEscape(code)+"\",\"modifiers\":"+ke.Modifiers+",\"location\":"+KeyLocation(ke.VK)+sys+"}}";
        Send(ws,j);
        string text=PrintableText(ke.VK,ke.Modifiers);
        if(down&&text.Length>0&&(ke.Modifiers&(1|2|4))==0){
            Send(ws,"{\"id\":"+NextId()+",\"method\":\"Input.dispatchKeyEvent\",\"params\":{\"type\":\"char\",\"text\":\""+JsonEscape(text)+"\"}}");
        }
    }
    static void Relay(){
        while(_ra){
            bool did=false;
            Evt e;if(_q.TryDequeue(out e)){
                did=true;
                for(int i=0;i<_slaves.Length;i++){
                    var port=_slaves[i];
                    try{
                        IntPtr hwnd=(i<_slaveWindows.Length)?_slaveWindows[i]:IntPtr.Zero;
                        if(DispatchWinMouse(hwnd,e))continue;
                        if(e.InPage==0)continue;
                        var ws=EnsureConn(port);if(ws==null)continue;
                        if(!_vp.ContainsKey(port))_vp[port]=QueryVp(_wsUrl[port]);
                        var vp=_vp[port];
                        Dispatch(ws,e,e.Px*vp[0]/10000,e.Py*vp[1]/10000);
                    }catch{Drop(port);}
                }
            }
            KbdEvt ke;if(_kq.TryDequeue(out ke)){
                did=true;
                for(int i=0;i<_slaves.Length;i++){
                    var port=_slaves[i];
                    try{
                        IntPtr hwnd=(i<_slaveWindows.Length)?_slaveWindows[i]:IntPtr.Zero;
                        if(DispatchWinKey(hwnd,ke))continue;
                        var ws=EnsureConn(port);if(ws==null)continue;
                        DispatchKey(ws,ke);
                    }catch{Drop(port);}
                }
            }
            if(!did)Thread.Sleep(3);
        }
    }
}
"@

Add-Type @"
using System; using System.IO; using System.Net; using System.Net.Sockets;
using System.Text; using System.Threading;
public class ProxyServer {
    public static void Start(int lp,string uh,int up,string usr,string pwd){
        string auth="Basic "+Convert.ToBase64String(Encoding.ASCII.GetBytes(usr+":"+pwd));
        var lis=new TcpListener(IPAddress.Loopback,lp);
        try{lis.Start();}catch{return;}
        new Thread(()=>{
            while(true){
                try{var c=lis.AcceptTcpClient();new Thread(()=>Handle(c,uh,up,auth)){IsBackground=true}.Start();}
                catch{break;}
            }
        }){IsBackground=true}.Start();
    }
    static void Handle(TcpClient lc,string uh,int up,string auth){
        try{
            using(lc){
                var ls=lc.GetStream();
                var hdr=new StringBuilder();
                int b; var prev=new int[]{0,0,0,0};
                while((b=ls.ReadByte())!=-1){
                    hdr.Append((char)b);
                    prev[0]=prev[1];prev[1]=prev[2];prev[2]=prev[3];prev[3]=b;
                    if(prev[0]==13&&prev[1]==10&&prev[2]==13&&prev[3]==10)break;
                }
                string req=hdr.ToString();
                if(string.IsNullOrEmpty(req))return;
                var lines=req.Split(new[]{"\r\n"},StringSplitOptions.None);
                if(lines.Length==0)return;
                var first=lines[0].Split(' ');
                if(first.Length<3)return;
                bool isCon=first[0]=="CONNECT";
                using(var rc=new TcpClient(uh,up)){
                    var rs=rc.GetStream();
                    if(isCon){
                        var cr="CONNECT "+first[1]+" HTTP/1.1\r\nHost: "+first[1]+"\r\nProxy-Authorization: "+auth+"\r\n\r\n";
                        var cb=Encoding.ASCII.GetBytes(cr);
                        rs.Write(cb,0,cb.Length);
                        var rbuf=new byte[4096]; int rn=rs.Read(rbuf,0,rbuf.Length);
                        var rsp=Encoding.ASCII.GetString(rbuf,0,rn);
                        if(rsp.Contains("200")){
                            var ok=Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection Established\r\n\r\n");
                            ls.Write(ok,0,ok.Length);
                            var t1=new Thread(()=>Pipe(ls,rs)){IsBackground=true};
                            t1.Start();Pipe(rs,ls);t1.Join(5000);
                        }
                    } else {
                        var sb=new StringBuilder();
                        sb.Append(lines[0]+"\r\n");
                        bool hasAuth=false;
                        for(int i=1;i<lines.Length;i++){
                            if(string.IsNullOrEmpty(lines[i]))continue;
                            if(lines[i].StartsWith("Proxy-Authorization:",StringComparison.OrdinalIgnoreCase)){hasAuth=true;sb.Append(lines[i]+"\r\n");}
                            else sb.Append(lines[i]+"\r\n");
                        }
                        if(!hasAuth)sb.Append("Proxy-Authorization: "+auth+"\r\n");
                        sb.Append("\r\n");
                        var fw=Encoding.UTF8.GetBytes(sb.ToString());
                        rs.Write(fw,0,fw.Length);
                        Pipe(rs,ls);
                    }
                }
            }
        }catch{}
    }
    static void Pipe(Stream f,Stream t){
        try{var buf=new byte[8192];int n;while((n=f.Read(buf,0,buf.Length))>0)t.Write(buf,0,n);}catch{}
    }
}
"@

$script:configDir   = Join-Path $env:APPDATA "ChromeManager"
if (-not (Test-Path $script:configDir)) { [void](New-Item -ItemType Directory -Path $script:configDir) }
$script:configFile  = Join-Path $script:configDir "profiles.json"
$script:settingsFile = Join-Path $script:configDir "settings.json"
$script:profileBase = Join-Path $script:configDir "Profiles"
$_chromePaths = @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$script:chrome = $_chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $script:chrome) { [System.Windows.MessageBox]::Show("未找到 Chrome，请手动安装。","错误") }
$script:profiles    = [System.Collections.ArrayList]::new()
$script:runtimeCacheAt = [datetime]::MinValue
$script:runtimeByPort  = @{}
$script:lastBadgeRefresh = [datetime]::MinValue
$script:lowMemoryMode = $false

function Load-Config {
    $script:profiles.Clear()
    if (Test-Path $script:configFile) {
        try {
            $data = Get-Content $script:configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $items = if ($data -is [System.Array]) { $data } else { @($data) }
            foreach ($item in $items) {
                [void]$script:profiles.Add([PSCustomObject]@{
                    id=([int]$item.id); name=([string]$item.name); group=([string]$item.group)
                    proxy=([string]$item.proxy); note=([string]$item.note)
                    pid=if($item.pid){[int]$item.pid}else{$null}
                    debugPort=if($item.debugPort){[int]$item.debugPort}else{19000+[int]$item.id}
                })
            }
        } catch {
            [System.Windows.MessageBox]::Show("配置文件读取失败: $($_.Exception.Message)","错误") | Out-Null
        }
    }
}
function Save-Config { ConvertTo-Json -InputObject @($script:profiles.ToArray()) -Depth 3 | Set-Content $script:configFile -Encoding UTF8 }
function Load-Settings {
    if (Test-Path $script:settingsFile) {
        try {
            $settings = Get-Content $script:settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $settings.lowMemoryMode) { $script:lowMemoryMode = [bool]$settings.lowMemoryMode }
        } catch {}
    }
}
function Save-Settings {
    @{ lowMemoryMode = [bool]$script:lowMemoryMode } | ConvertTo-Json -Depth 2 | Set-Content $script:settingsFile -Encoding UTF8
}
function Get-LowMemoryChromeArgs {
    return @(
        "--disable-background-networking",
        "--disable-client-side-phishing-detection",
        "--disable-component-extensions-with-background-pages",
        "--disable-default-apps",
        "--disable-domain-reliability",
        "--disable-extensions",
        "--disable-notifications",
        "--disable-sync",
        "--disable-features=AutofillServerCommunication,InterestFeedContentSuggestions,MediaRouter,OptimizationHints,Translate",
        "--disk-cache-size=104857600",
        "--media-cache-size=16777216",
        "--process-per-site",
        "--renderer-process-limit=3"
    )
}
function Update-RuntimeCache {
    if (((Get-Date) - $script:runtimeCacheAt).TotalMilliseconds -lt 800) { return }
    $map = @{}
    try {
        $items = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue
        foreach ($ci in @($items)) {
            $cmd = [string]$ci.CommandLine
            if ($cmd -match '--remote-debugging-port=(\d+)') {
                $port = [int]$Matches[1]
                try {
                    $proc = Get-Process -Id ([int]$ci.ProcessId) -ErrorAction Stop
                    if (-not $map.ContainsKey($port) -or [int64]$map[$port].MainWindowHandle -eq 0 -or [int64]$proc.MainWindowHandle -ne 0) {
                        $map[$port] = $proc
                    }
                } catch {}
            }
        }
    } catch {}
    $script:runtimeByPort = $map
    $script:runtimeCacheAt = Get-Date
}
function Test-DebugPort([int]$port) {
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $ar = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(150)) { return $false }
        $client.EndConnect($ar)
        return $true
    } catch { return $false }
    finally { if ($client) { $client.Close() } }
}
function Get-ProfileChromeProcess([PSCustomObject]$p) {
    Update-RuntimeCache
    $port = [int]$p.debugPort
    if ($script:runtimeByPort.ContainsKey($port)) { return $script:runtimeByPort[$port] }
    if ($p.pid -and [int]$p.pid -gt 0) {
        try {
            $proc = Get-Process -Id ([int]$p.pid) -ErrorAction Stop
            if ($proc.ProcessName -eq "chrome") { return $proc }
        } catch {}
    }
    return $null
}
function Sync-ProfileRuntime([PSCustomObject]$p) {
    $proc = Get-ProfileChromeProcess $p
    if ($proc) {
        if ([int]$p.pid -ne [int]$proc.Id) { $p.pid = [int]$proc.Id }
        return $true
    }
    if (Test-DebugPort ([int]$p.debugPort)) { return $true }
    if ($p.pid) { $p.pid = $null }
    return $false
}
function Get-ProfileWindowHandle([PSCustomObject]$p) {
    $proc = Get-ProfileChromeProcess $p
    if ($proc) {
        $p.pid = [int]$proc.Id
        if ([int64]$proc.MainWindowHandle -ne 0) { return [IntPtr]$proc.MainWindowHandle }
    }
    if ($p.pid -and [int]$p.pid -gt 0) { return [MouseSync]::FindChromeWindow([int]$p.pid) }
    return [IntPtr]::Zero
}
function Is-Running([PSCustomObject]$p) {
    return (Sync-ProfileRuntime $p)
}
function Get-NextId {
    if ($script:profiles.Count -eq 0) { return 1 }
    $max = 0; foreach ($p in $script:profiles) { if ([int]$p.id -gt $max) { $max = [int]$p.id } }; return $max + 1
}
function Launch-Profile([PSCustomObject]$p) {
    if (Is-Running $p) { return }
    $dir = "$script:profileBase\$($p.name)"
    if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $a = @("--user-data-dir=`"$dir`"", "--remote-debugging-port=$($p.debugPort)", "--no-first-run", "--no-default-browser-check")
    if ($script:lowMemoryMode) { $a += Get-LowMemoryChromeArgs }
    if ($p.proxy -and $p.proxy.Trim()) {
        if ($p.proxy -match '^https?://([^:@]+):([^@]+)@([^:]+):(\d+)') {
            $lp = 20000 + [int]$p.id
            [ProxyServer]::Start($lp, $Matches[3], [int]$Matches[4], $Matches[1], $Matches[2])
            $a += "--proxy-server=http://127.0.0.1:$lp"
        } else {
            $a += "--proxy-server=$($p.proxy.Trim())"
        }
    }
    $started = Start-Process $script:chrome -ArgumentList $a -PassThru
    $p.pid = $started.Id
    $script:runtimeCacheAt = [datetime]::MinValue
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 200
        $script:runtimeCacheAt = [datetime]::MinValue
        $realProc = Get-ProfileChromeProcess $p
        if ($realProc) { $p.pid = [int]$realProc.Id; break }
    }
    Save-Config
}
function Stop-Profile([PSCustomObject]$p) {
    $proc = Get-ProfileChromeProcess $p
    if ($proc) { Stop-Process -Id ([int]$proc.Id) -Force -ErrorAction SilentlyContinue }
    elseif ($p.pid -and [int]$p.pid -gt 0) { Stop-Process -Id ([int]$p.pid) -Force -ErrorAction SilentlyContinue }
    $p.pid = $null; Save-Config
    $script:runtimeCacheAt = [datetime]::MinValue
}
function Arrange-All {
    Add-Type -AssemblyName System.Windows.Forms
    $sc = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $ps = @(Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle })
    if ($ps.Count -eq 0) { return 0 }
    $cols = [int][Math]::Ceiling([Math]::Sqrt($ps.Count * $sc.Width / $sc.Height))
    $ww = [int]($sc.Width / $cols); $wh = [int]($sc.Height / [int][Math]::Ceiling($ps.Count / $cols))
    for ($i = 0; $i -lt $ps.Count; $i++) {
        [void][WinAPI2]::ShowWindow($ps[$i].MainWindowHandle, 9)
        [void][WinAPI2]::SetWindowPos($ps[$i].MainWindowHandle, [IntPtr]::Zero, ($sc.Left + ($i % $cols) * $ww), ($sc.Top + ([int]($i / $cols)) * $wh), $ww, $wh, 0x0040)
    }
    return $ps.Count
}
function CDP-Nav($port, $url) {
    try {
        $t = @(Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 2 | Where-Object { $_.type -eq "page" })
        if ($t.Count -eq 0) { return $false }
        $payload = @{ id=1; method="Page.navigate"; params=@{ url=$url } } | ConvertTo-Json -Compress -Depth 5
        [CDP2]::Send($t[0].webSocketDebuggerUrl, $payload) | Out-Null
        return $true
    } catch { return $false }
}
function CDP-Eval($port, $expr) {
    try {
        $t = @(Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 2 | Where-Object { $_.type -eq "page" })
        if ($t.Count -eq 0) { return $false }
        $payload = @{ id=1; method="Runtime.evaluate"; params=@{ expression=$expr } } | ConvertTo-Json -Compress -Depth 5
        [CDP2]::Send($t[0].webSocketDebuggerUrl, $payload) | Out-Null
        return $true
    } catch { return $false }
}
function ConvertTo-JsValue($value) {
    if ($null -eq $value) { return "null" }
    return ($value | ConvertTo-Json -Compress)
}
function Get-ProfileProxyHost([PSCustomObject]$p) {
    $proxy = ([string]$p.proxy).Trim()
    if (-not $proxy) { return "" }
    if ($proxy -match '^[a-zA-Z]+://[^:@/]+:[^@/]+@([^:/]+):(\d+)') { return $Matches[1] }
    if ($proxy -match '^[a-zA-Z]+://([^:/]+):(\d+)') { return $Matches[1] }
    if ($proxy -match '^([^:/]+):(\d+)') { return $Matches[1] }
    return ""
}
function Update-ProfileBadge([PSCustomObject]$p) {
    if (-not (Is-Running $p)) { return $false }
    $profileId = [int]$p.id
    $profileName = ConvertTo-JsValue ([string]$p.name)
    $configuredIp = ConvertTo-JsValue (Get-ProfileProxyHost $p)
    $js = @"
(function(){
  const badgeId = '__chrome_manager_window_badge';
  const windowNo = $profileId;
  const profileName = $profileName;
  const configuredIp = $configuredIp;
  const title = '窗口 #' + windowNo + (profileName ? '  ' + profileName : '');
  function ensureBadge(){
    let el = document.getElementById(badgeId);
    if (!el) {
      el = document.createElement('div');
      el.id = badgeId;
      const root = document.body || document.documentElement;
      root.appendChild(el);
    }
    el.style.cssText = [
      'position:fixed',
      'left:8px',
      'top:8px',
      'z-index:2147483647',
      'padding:5px 8px',
      'border-radius:6px',
      'background:rgba(17,24,39,.88)',
      'color:#fff',
      'border:1px solid rgba(255,255,255,.22)',
      'font:12px/1.35 Arial,Microsoft YaHei,sans-serif',
      'letter-spacing:0',
      'box-shadow:0 4px 14px rgba(0,0,0,.22)',
      'pointer-events:none',
      'white-space:nowrap'
    ].join(';');
    return el;
  }
  function setBadge(ip, source){
    const el = ensureBadge();
    el.textContent = title + '  |  ' + source + ': ' + (ip || '未知');
  }
  setBadge(configuredIp || '检测中', configuredIp ? '配置IP' : '出口IP');
  fetch('https://api.ipify.org?format=json', { cache: 'no-store' })
    .then(function(r){ return r.json(); })
    .then(function(data){ if (data && data.ip) setBadge(data.ip, '出口IP'); })
    .catch(function(){ if (!configuredIp) setBadge('', '出口IP'); });
})();
"@
    return (CDP-Eval $p.debugPort $js)
}
function Refresh-WindowBadges([int]$minSeconds = 12) {
    if ($minSeconds -gt 0 -and ((Get-Date) - $script:lastBadgeRefresh).TotalSeconds -lt $minSeconds) { return }
    $script:lastBadgeRefresh = Get-Date
    foreach ($p in $script:profiles) {
        if (Is-Running $p) { [void](Update-ProfileBadge $p) }
    }
}

Load-Settings

# ==================== XAML ====================
[xml]$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Chrome 多开管理器 v1.0"
        Height="740" Width="1120" MinHeight="580" MinWidth="900"
        Background="#0f0f17" WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI" FontSize="13">
<Window.Resources>
  <ControlTemplate x:Key="FlatBtn" TargetType="Button">
    <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
      <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="2,0,0,0"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.78"/></Trigger>
      <Trigger Property="IsPressed"   Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.55"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>
  <ControlTemplate x:Key="ActionBtn" TargetType="Button">
    <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.78"/></Trigger>
      <Trigger Property="IsPressed"   Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.55"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>
  <Style x:Key="SBtn" TargetType="Button">
    <Setter Property="Background" Value="#252535"/><Setter Property="Foreground" Value="#c0c0d8"/>
    <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="13,8"/><Setter Property="Margin" Value="10,3"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/><Setter Property="HorizontalContentAlignment" Value="Left"/>
    <Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="12"/>
    <Setter Property="FontFamily" Value="Microsoft YaHei UI"/><Setter Property="Template" Value="{StaticResource FlatBtn}"/>
  </Style>
  <Style x:Key="BlueBtn"   BasedOn="{StaticResource SBtn}" TargetType="Button"><Setter Property="Background" Value="#1a3560"/><Setter Property="Foreground" Value="#82b4ff"/></Style>
  <Style x:Key="GreenBtn"  BasedOn="{StaticResource SBtn}" TargetType="Button"><Setter Property="Background" Value="#183d22"/><Setter Property="Foreground" Value="#7dd87d"/></Style>
  <Style x:Key="RedBtn"    BasedOn="{StaticResource SBtn}" TargetType="Button"><Setter Property="Background" Value="#3d1818"/><Setter Property="Foreground" Value="#f07070"/></Style>
  <Style x:Key="PurpleBtn" BasedOn="{StaticResource SBtn}" TargetType="Button"><Setter Property="Background" Value="#2a1848"/><Setter Property="Foreground" Value="#c084fc"/></Style>
  <Style x:Key="OrangeBtn" BasedOn="{StaticResource SBtn}" TargetType="Button"><Setter Property="Background" Value="#3d2710"/><Setter Property="Foreground" Value="#f0a855"/></Style>
  <Style TargetType="DataGrid">
    <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#c0c0d8"/>
    <Setter Property="BorderThickness" Value="0"/><Setter Property="GridLinesVisibility" Value="Horizontal"/>
    <Setter Property="HorizontalGridLinesBrush" Value="#1e1e30"/><Setter Property="RowBackground" Value="Transparent"/>
    <Setter Property="AlternatingRowBackground" Value="#12121e"/><Setter Property="ColumnHeaderHeight" Value="38"/>
    <Setter Property="RowHeight" Value="34"/><Setter Property="SelectionMode" Value="Extended"/><Setter Property="SelectionUnit" Value="FullRow"/>
  </Style>
  <Style TargetType="DataGridColumnHeader">
    <Setter Property="Background" Value="#0a0a12"/><Setter Property="Foreground" Value="#7070a0"/>
    <Setter Property="Padding" Value="14,0"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="BorderBrush" Value="#1e1e30"/>
    <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="12"/><Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
  </Style>
  <Style TargetType="DataGridRow">
    <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
    <Style.Triggers>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#1c3060"/></Trigger>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1a1a2a"/></Trigger>
      <DataTrigger Binding="{Binding [status]}" Value="运行中"><Setter Property="Foreground" Value="#60d080"/></DataTrigger>
    </Style.Triggers>
  </Style>
  <Style TargetType="DataGridCell">
    <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="2,0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="DataGridCell">
          <Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}">
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#e0e8ff"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style TargetType="ScrollBar"><Setter Property="Width" Value="6"/><Setter Property="Background" Value="Transparent"/></Style>
  <Style x:Key="DarkTb" TargetType="TextBox">
    <Setter Property="Background" Value="#1a1a2a"/><Setter Property="Foreground" Value="#c0c0d8"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="BorderBrush" Value="#2a2a45"/>
    <Setter Property="Padding" Value="10,7"/><Setter Property="CaretBrush" Value="#82b4ff"/>
    <Setter Property="FontFamily" Value="Microsoft YaHei UI"/><Setter Property="FontSize" Value="12"/>
  </Style>
  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="#5a5a7a"/><Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
    <Setter Property="FontSize" Value="12"/><Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>
  <Style TargetType="ContextMenu">
    <Setter Property="Background" Value="#1e1e30"/><Setter Property="Foreground" Value="#c0c0d8"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="BorderBrush" Value="#2e2e48"/>
    <Setter Property="Padding" Value="2"/><Setter Property="FontFamily" Value="Microsoft YaHei UI"/><Setter Property="FontSize" Value="12"/>
  </Style>
  <Style TargetType="MenuItem">
    <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#c0c0d8"/>
    <Setter Property="Padding" Value="14,7"/><Setter Property="FontFamily" Value="Microsoft YaHei UI"/><Setter Property="FontSize" Value="12"/>
  </Style>
</Window.Resources>
<Grid>
  <Grid.RowDefinitions>
    <RowDefinition Height="54"/><RowDefinition Height="*"/>
    <RowDefinition Height="Auto"/><RowDefinition Height="26"/>
  </Grid.RowDefinitions>
  <!-- Header -->
  <Border Grid.Row="0" Background="#08080f">
    <Grid Margin="18,0">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Ellipse Width="10" Height="10" Fill="#82b4ff" Margin="0,0,10,0"/>
        <TextBlock Text="Chrome" FontSize="19" FontWeight="Bold" Foreground="#82b4ff" VerticalAlignment="Center"/>
        <TextBlock Text=" 多开管理器" FontSize="19" Foreground="#c0c0d8" VerticalAlignment="Center"/>
        <TextBlock Text="  v1.0" FontSize="10" Foreground="#3a3a58" VerticalAlignment="Bottom" Margin="0,0,0,2"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Border Background="#183d22" CornerRadius="5" Padding="12,5" Margin="0,0,8,0">
          <TextBlock x:Name="lblRunning" Text="运行中: 0" Foreground="#60d080" FontSize="12" FontWeight="SemiBold"/>
        </Border>
        <Border Background="#1e1e30" CornerRadius="5" Padding="12,5" Margin="0,0,8,0">
          <TextBlock x:Name="lblStopped" Text="已停止: 0" Foreground="#5a5a7a" FontSize="12"/>
        </Border>
        <Border Background="#1e1e30" CornerRadius="5" Padding="12,5">
          <TextBlock x:Name="lblTotal" Text="共 0 个" Foreground="#8080a0" FontSize="12"/>
        </Border>
      </StackPanel>
    </Grid>
  </Border>
  <!-- Main -->
  <Grid Grid.Row="1">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="178"/><ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>
    <Border Grid.Column="0" Background="#0c0c18">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="0,14,0,14">
          <TextBlock Text="配置管理" FontSize="10" Foreground="#3a3a58" Margin="18,0,0,6" FontWeight="Bold"/>
          <Button x:Name="btnNew"    Content="+ 新建配置" Style="{StaticResource BlueBtn}"/>
          <Button x:Name="btnEdit"   Content="  编辑选中" Style="{StaticResource SBtn}"/>
          <Button x:Name="btnDelete" Content="  删除选中" Style="{StaticResource RedBtn}"/>
          <Rectangle Height="1" Fill="#1a1a28" Margin="10,10"/>
          <TextBlock Text="启动控制" FontSize="10" Foreground="#3a3a58" Margin="18,0,0,6" FontWeight="Bold"/>
          <Button x:Name="btnLaunch"    Content="▶  启动选中" Style="{StaticResource GreenBtn}"/>
          <Button x:Name="btnLaunchAll" Content="▶  全部启动" Style="{StaticResource GreenBtn}"/>
          <Button x:Name="btnStop"      Content="■  关闭选中" Style="{StaticResource RedBtn}"/>
          <Button x:Name="btnStopAll"   Content="■  全部关闭" Style="{StaticResource RedBtn}"/>
          <Rectangle Height="1" Fill="#1a1a28" Margin="10,10"/>
          <TextBlock Text="工具" FontSize="10" Foreground="#3a3a58" Margin="18,0,0,6" FontWeight="Bold"/>
          <Button x:Name="btnArrange"  Content="⊞  排列窗口" Style="{StaticResource PurpleBtn}"/>
          <Button x:Name="btnImport"   Content="↓  导入代理" Style="{StaticResource OrangeBtn}"/>
          <Button x:Name="btnRefresh"  Content="↺  刷新状态" Style="{StaticResource SBtn}"/>
          <Button x:Name="btnSyncMouse" Content="◎  同步鼠标/键盘" Style="{StaticResource SBtn}"/>
          <CheckBox x:Name="chkLowMemory" Content="低内存模式" Margin="14,10,10,0"
                    ToolTip="只对新启动的窗口生效；会禁用扩展和部分 Chrome 后台服务以降低占用。"/>
        </StackPanel>
      </ScrollViewer>
    </Border>
    <Border Grid.Column="1" Background="#0f0f17" BorderThickness="1,0,0,0" BorderBrush="#1a1a28">
      <DataGrid x:Name="profileGrid"
                CanUserAddRows="False" CanUserDeleteRows="False"
                CanUserResizeRows="False" IsReadOnly="True"
                AutoGenerateColumns="False" HeadersVisibility="Column">
        <DataGrid.ContextMenu>
          <ContextMenu>
            <MenuItem x:Name="ctxLaunch"  Header="启动"/>
            <MenuItem x:Name="ctxStop"    Header="关闭"/>
            <MenuItem x:Name="ctxSetMaster" Header="设为主控"/>
            <Separator Background="#2e2e48"/>
            <MenuItem x:Name="ctxEdit"   Header="编辑"/>
            <MenuItem x:Name="ctxDelete" Header="删除"/>
          </ContextMenu>
        </DataGrid.ContextMenu>
        <DataGrid.Columns>
          <DataGridTextColumn Header="#"    Binding="{Binding [id]}"     Width="50"  MinWidth="40"/>
          <DataGridTextColumn Header="名称" Binding="{Binding [name]}"   Width="130" MinWidth="80"/>
          <DataGridTextColumn Header="分组" Binding="{Binding [group]}"  Width="80"  MinWidth="60"/>
          <DataGridTextColumn Header="代理" Binding="{Binding [proxy]}"  Width="*"   MinWidth="200"/>
          <DataGridTextColumn Header="状态" Binding="{Binding [status]}" Width="80"  MinWidth="70"/>
          <DataGridTextColumn Header="备注" Binding="{Binding [note]}"   Width="110" MinWidth="60"/>
        </DataGrid.Columns>
      </DataGrid>
    </Border>
  </Grid>
  <!-- Group control -->
  <Border Grid.Row="2" Background="#0c0c18" Padding="18,12" BorderThickness="0,1,0,0" BorderBrush="#1a1a28">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="24"/>
        <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="#2a1848" CornerRadius="6" Padding="12,5" Margin="0,0,12,0" VerticalAlignment="Center">
        <TextBlock Text="群控" Foreground="#c084fc" FontWeight="Bold" FontSize="12"/>
      </Border>
      <CheckBox x:Name="gcOnlySel" Grid.Column="1" Content="仅选中" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <TextBlock Grid.Column="2" Text="地址" Foreground="#4a4a6a" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12"/>
      <TextBox   x:Name="gcUrl"  Grid.Column="3" Style="{StaticResource DarkTb}" VerticalAlignment="Center" Height="32"/>
      <Button    x:Name="gcGoto" Grid.Column="4" Content="全部跳转" Margin="8,0,0,0"
                 Background="#1a3560" Foreground="#82b4ff" Padding="14,7" BorderThickness="0" Cursor="Hand"
                 FontFamily="Microsoft YaHei UI" FontSize="12" Template="{StaticResource ActionBtn}"/>
      <TextBlock Grid.Column="6" Text="脚本" Foreground="#4a4a6a" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12"/>
      <TextBox   x:Name="gcJs"   Grid.Column="7" Style="{StaticResource DarkTb}" VerticalAlignment="Center" Height="32"/>
      <Button    x:Name="gcExec" Grid.Column="8" Content="执 行" Margin="8,0,0,0"
                 Background="#2a1848" Foreground="#c084fc" Padding="14,7" BorderThickness="0" Cursor="Hand"
                 FontFamily="Microsoft YaHei UI" FontSize="12" Template="{StaticResource ActionBtn}"/>
    </Grid>
  </Border>
  <!-- Status bar -->
  <Border Grid.Row="3" Background="#060609">
    <TextBlock x:Name="statusBar" Text="就绪" Foreground="#3a3a58" FontSize="11" VerticalAlignment="Center" Margin="18,0"/>
  </Border>
</Grid>
</Window>
'@

[xml]$DlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="310" Width="500" ResizeMode="NoResize"
        Background="#0f0f17" Foreground="#c0c0d8"
        FontFamily="Microsoft YaHei UI" FontSize="13"
        WindowStartupLocation="CenterOwner">
  <Grid Margin="24,20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="14"/>  <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions><ColumnDefinition Width="55"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <TextBlock Grid.Row="0" Grid.Column="0" Text="名称" Foreground="#5a5a7a" VerticalAlignment="Center" Margin="0,0,0,10"/>
    <TextBlock Grid.Row="1" Grid.Column="0" Text="分组" Foreground="#5a5a7a" VerticalAlignment="Center" Margin="0,0,0,10"/>
    <TextBlock Grid.Row="2" Grid.Column="0" Text="代理" Foreground="#5a5a7a" VerticalAlignment="Center" Margin="0,0,0,10"/>
    <TextBlock Grid.Row="3" Grid.Column="0" Text="备注" Foreground="#5a5a7a" VerticalAlignment="Center"/>
    <TextBox x:Name="tbName"  Grid.Row="0" Grid.Column="1" Margin="0,0,0,10" Height="32" Background="#1a1a2a" Foreground="#c0c0d8" BorderBrush="#2a2a45" BorderThickness="1" Padding="10,6" CaretBrush="#82b4ff"/>
    <TextBox x:Name="tbGroup" Grid.Row="1" Grid.Column="1" Margin="0,0,0,10" Height="32" Background="#1a1a2a" Foreground="#c0c0d8" BorderBrush="#2a2a45" BorderThickness="1" Padding="10,6" CaretBrush="#82b4ff"/>
    <TextBox x:Name="tbProxy" Grid.Row="2" Grid.Column="1" Margin="0,0,0,10" Height="32" Background="#1a1a2a" Foreground="#c0c0d8" BorderBrush="#2a2a45" BorderThickness="1" Padding="10,6" CaretBrush="#82b4ff"/>
    <TextBox x:Name="tbNote"  Grid.Row="3" Grid.Column="1"                   Height="32" Background="#1a1a2a" Foreground="#c0c0d8" BorderBrush="#2a2a45" BorderThickness="1" Padding="10,6" CaretBrush="#82b4ff"/>
    <TextBlock Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="2" Text="代理格式:  http://用户名:密码@IP:端口" FontSize="11" Foreground="#3a3a58" VerticalAlignment="Center"/>
    <StackPanel Grid.Row="5" Grid.Column="0" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="btnOk"  Content="确  定" Width="90" Height="34" Margin="0,0,10,0" Background="#1a3560" Foreground="#82b4ff" BorderThickness="0" Cursor="Hand"/>
      <Button x:Name="btnCan" Content="取  消" Width="90" Height="34"                   Background="#252535" Foreground="#7070a0" BorderThickness="0" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@

# ==================== Load UI ====================
$reader = New-Object System.Xml.XmlNodeReader($MainXaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$profileGrid  = $window.FindName("profileGrid")
$btnNew       = $window.FindName("btnNew");   $btnEdit      = $window.FindName("btnEdit")
$btnDelete    = $window.FindName("btnDelete"); $btnLaunch    = $window.FindName("btnLaunch")
$btnLaunchAll = $window.FindName("btnLaunchAll"); $btnStop   = $window.FindName("btnStop")
$btnStopAll   = $window.FindName("btnStopAll");   $btnArrange= $window.FindName("btnArrange")
$btnImport    = $window.FindName("btnImport");    $btnRefresh= $window.FindName("btnRefresh")
$lblRunning   = $window.FindName("lblRunning");   $lblStopped= $window.FindName("lblStopped")
$lblTotal     = $window.FindName("lblTotal");     $statusBar = $window.FindName("statusBar")
$chkLowMemory = $window.FindName("chkLowMemory")
$gcOnlySel    = $window.FindName("gcOnlySel");    $gcUrl     = $window.FindName("gcUrl")
$gcGoto       = $window.FindName("gcGoto");       $gcJs      = $window.FindName("gcJs")
$gcExec       = $window.FindName("gcExec")
$ctxLaunch    = $window.FindName("ctxLaunch");    $ctxStop      = $window.FindName("ctxStop")
$ctxEdit      = $window.FindName("ctxEdit");      $ctxDelete    = $window.FindName("ctxDelete")
$ctxSetMaster = $window.FindName("ctxSetMaster"); $btnSyncMouse = $window.FindName("btnSyncMouse")

$script:dt = New-Object System.Data.DataTable
@("id","name","group","proxy","status","note") | ForEach-Object { [void]$script:dt.Columns.Add($_) }
$profileGrid.ItemsSource = $script:dt.DefaultView

# ==================== Functions ====================
function Set-Status($msg) { $statusBar.Text = $msg }
function Write-AppLog($msg) {
    try {
        $log = Join-Path $script:configDir "ChromeManager.log"
        Add-Content -LiteralPath $log -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg)
    } catch {}
}

$window.Dispatcher.add_UnhandledException({
    param($sender, $e)
    Write-AppLog ("DispatcherUnhandledException: " + $e.Exception.ToString())
    $e.Handled = $true
    try { Set-Status "发生异常，已记录日志: $script:configDir\\ChromeManager.log" } catch {}
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    try { Write-AppLog ("UnhandledException: " + $e.ExceptionObject.ToString()) } catch {}
})

function Refresh-UI {
    $script:dt.Rows.Clear()
    foreach ($p in $script:profiles) {
        $r = $script:dt.NewRow()
        $r["id"] = "$($p.id)"; $r["name"] = $p.name; $r["group"] = $p.group
        $r["proxy"] = $p.proxy; $r["status"] = if (Is-Running $p) { "运行中" } else { "已停止" }; $r["note"] = $p.note
        [void]$script:dt.Rows.Add($r)
    }
    $total = $script:profiles.Count
    $run   = ($script:profiles | Where-Object { Is-Running $_ }).Count
    $lblRunning.Text = "运行中: $run"; $lblStopped.Text = "已停止: $($total - $run)"; $lblTotal.Text = "共 $total 个"
    $lm = if ($script:lowMemoryMode) { "开" } else { "关" }
    Set-Status "配置: $total   运行中: $run   已停止: $($total - $run)   低内存: $lm   双击行切换启动/停止"
}

function Get-SelectedProfiles {
    return @($profileGrid.SelectedItems | ForEach-Object {
        $id = [int]$_["id"]; $script:profiles | Where-Object { $_.id -eq $id }
    } | Where-Object { $_ })
}

function Show-EditDlg($title, $p) {
    $dr  = New-Object System.Xml.XmlNodeReader($DlgXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($dr)
    $dlg.Owner = $window; $dlg.Title = $title
    $tn = $dlg.FindName("tbName"); $tg = $dlg.FindName("tbGroup")
    $tp = $dlg.FindName("tbProxy"); $tno = $dlg.FindName("tbNote")
    $ok = $dlg.FindName("btnOk"); $can = $dlg.FindName("btnCan")
    if ($p) { $tn.Text = $p.name; $tg.Text = $p.group; $tp.Text = $p.proxy; $tno.Text = $p.note }
    else    { $tg.Text = "默认" }
    $ok.Add_Click({ $dlg.DialogResult = $true })
    $can.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    if ($dlg.ShowDialog() -and $tn.Text.Trim()) {
        return @{ name = $tn.Text.Trim(); group = $tg.Text.Trim(); proxy = $tp.Text.Trim(); note = $tno.Text.Trim() }
    }
    return $null
}

# ==================== Events ====================
$chkLowMemory.IsChecked = [bool]$script:lowMemoryMode
$chkLowMemory.Add_Checked({
    $script:lowMemoryMode = $true
    Save-Settings
    Set-Status "低内存模式已开启；新启动或重新启动窗口后生效。"
})
$chkLowMemory.Add_Unchecked({
    $script:lowMemoryMode = $false
    Save-Settings
    Set-Status "低内存模式已关闭；新启动或重新启动窗口后生效。"
})

$btnNew.Add_Click({
    $d = Show-EditDlg "新建配置" $null
    if ($d) {
        $nid = Get-NextId
        [void]$script:profiles.Add([PSCustomObject]@{ id=$nid; name=$d.name; group=$d.group; proxy=$d.proxy; pid=$null; debugPort=(19000+$nid); note=$d.note })
        Save-Config; Refresh-UI; Set-Status "已创建: $($d.name)"
    }
})
$btnEdit.Add_Click({
    $sel = Get-SelectedProfiles
    if ($sel.Count -ne 1) { [System.Windows.MessageBox]::Show("请选中一个配置进行编辑。", "提示") | Out-Null; return }
    $d = Show-EditDlg "编辑配置" $sel[0]
    if ($d) { $sel[0].name=$d.name; $sel[0].group=$d.group; $sel[0].proxy=$d.proxy; $sel[0].note=$d.note; Save-Config; Refresh-UI }
})
$btnDelete.Add_Click({
    $sel = Get-SelectedProfiles; if ($sel.Count -eq 0) { return }
    if ([System.Windows.MessageBox]::Show("确认删除 $($sel.Count) 个配置？","确认","YesNo","Question") -eq "Yes") {
        foreach ($p in $sel) { Stop-Profile $p; [void]$script:profiles.Remove($p) }
        Save-Config; Refresh-UI
    }
})
$btnLaunch.Add_Click({
    $sel = Get-SelectedProfiles; if ($sel.Count -eq 0) { Set-Status "请先选中配置。"; return }
    foreach ($p in $sel) { Launch-Profile $p; Start-Sleep -Milliseconds 600 }
    Refresh-WindowBadges 0
    Refresh-UI; Set-Status "已启动 $($sel.Count) 个配置。"
})
$btnLaunchAll.Add_Click({
    # Stop running profiles first so proxy settings refresh
    foreach ($p in $script:profiles) { if (Is-Running $p) { Stop-Profile $p } }
    $n = 0; foreach ($p in $script:profiles) { Launch-Profile $p; Start-Sleep -Milliseconds 800; $n++ }
    Refresh-WindowBadges 0
    Refresh-UI; Set-Status "已启动 $n 个配置。"
})
$btnStop.Add_Click({
    $sel = Get-SelectedProfiles; if ($sel.Count -eq 0) { return }
    foreach ($p in $sel) { Stop-Profile $p }; Refresh-UI; Set-Status "已关闭 $($sel.Count) 个配置。"
})
$btnStopAll.Add_Click({ foreach ($p in $script:profiles) { Stop-Profile $p }; Refresh-UI; Set-Status "全部已关闭。" })
$btnArrange.Add_Click({ $n = Arrange-All; Set-Status "已排列 $n 个窗口。" })
$btnImport.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = "文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*"
    $ofd.Title  = "选择代理文件 (格式: IP:端口:用户名:密码)"
    if ($ofd.ShowDialog($window) -ne $true) { return }
    $n = 0
    foreach ($line in (Get-Content $ofd.FileName | Where-Object { $_.Trim() })) {
        $pt = $line.Trim() -split ":"
        if ($pt.Count -ge 4) {
            $nid = Get-NextId
            [void]$script:profiles.Add([PSCustomObject]@{
                id=$nid; name="账号$nid"; group="默认"
                proxy="http://$($pt[2]):$($pt[3..($pt.Count-1)] -join ':')@$($pt[0]):$($pt[1])"
                pid=$null; debugPort=(19000+$nid); note=""
            }); $n++
        }
    }
    Save-Config; Refresh-UI; Set-Status "已导入 $n 个代理配置。"
})
$btnRefresh.Add_Click({ Refresh-UI; Refresh-WindowBadges 0 })
$profileGrid.Add_MouseDoubleClick({
    $sel = Get-SelectedProfiles
    foreach ($p in $sel) { if (Is-Running $p) { Stop-Profile $p } else { Launch-Profile $p } }
    Refresh-UI; Refresh-WindowBadges 0
})
$ctxLaunch.Add_Click({ $sel=Get-SelectedProfiles; foreach($p in $sel){Launch-Profile $p;Start-Sleep -Milliseconds 500}; Refresh-UI; Refresh-WindowBadges 0 })
$ctxStop.Add_Click({   $sel=Get-SelectedProfiles; foreach($p in $sel){Stop-Profile $p}; Refresh-UI })
$ctxEdit.Add_Click({   $btnEdit.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) })
$ctxDelete.Add_Click({ $btnDelete.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) })
$gcGoto.Add_Click({
    $url = $gcUrl.Text.Trim(); if (-not $url) { Set-Status "请输入地址。"; return }
    if (-not $url.StartsWith("http")) { $url = "https://$url" }
    $targets = if ($gcOnlySel.IsChecked) { Get-SelectedProfiles } else { $script:profiles }
    $n = 0; foreach ($p in @($targets)) { if (Is-Running $p -and (CDP-Nav $p.debugPort $url)) { $n++ } }
    Start-Sleep -Milliseconds 700
    Refresh-WindowBadges 0
    Set-Status "群控跳转: 已向 $n 个窗口发送 -> $url"
})
$gcUrl.Add_KeyDown({ if ($_.Key -eq "Return") { $gcGoto.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) } })
$gcExec.Add_Click({
    $js = $gcJs.Text.Trim(); if (-not $js) { Set-Status "请输入脚本。"; return }
    $targets = if ($gcOnlySel.IsChecked) { Get-SelectedProfiles } else { $script:profiles }
    $n = 0; foreach ($p in @($targets)) { if (Is-Running $p -and (CDP-Eval $p.debugPort $js)) { $n++ } }
    Refresh-WindowBadges 0
    Set-Status "群控执行: 已向 $n 个窗口执行脚本。"
})
$gcJs.Add_KeyDown({ if ($_.Key -eq "Return") { $gcExec.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) } })

$script:syncMaster = $null
$script:syncActive = $false

function Get-RunningProfiles {
    return @($script:profiles | Where-Object { Is-Running $_ })
}
function Resolve-SyncMaster {
    $sel = Get-SelectedProfiles
    $selectedRunning = @($sel | Where-Object { Is-Running $_ })
    if ($selectedRunning.Count -gt 0) { return $selectedRunning[0] }
    if ($script:syncMaster -and (Is-Running $script:syncMaster)) { return $script:syncMaster }
    $running = Get-RunningProfiles
    if ($running.Count -gt 0) { return $running[0] }
    return $null
}
function Set-SyncMaster([PSCustomObject]$p) {
    if (-not $p -or -not (Is-Running $p)) { return $false }
    $script:syncMaster = $p
    [MouseSync]::MasterHwnd = Get-ProfileWindowHandle $p
    if ([MouseSync]::MasterHwnd -eq [IntPtr]::Zero) {
        [System.Windows.MessageBox]::Show("找不到该配置对应的 Chrome 窗口，请先启动或重新排列窗口后再试。","提示") | Out-Null
        return $false
    }
    [MouseSync]::MasterPid = [int]$p.pid
    return $true
}

$ctxSetMaster.Add_Click({
    $master = Resolve-SyncMaster
    if (-not $master) { [System.Windows.MessageBox]::Show("没有运行中的窗口。请先启动至少两个配置。","提示") | Out-Null; return }
    if (-not (Set-SyncMaster $master)) { return }
    Set-Status "主控已设为: $($script:syncMaster.name)  HWND=$([MouseSync]::MasterHwnd)  (点击 [同步鼠标] 开始)"
})

$btnSyncMouse.Add_Click({
    if ($script:syncActive) {
        $script:syncActive = $false
        [MouseSync]::StopAll()
        $btnSyncMouse.Content = "◎  同步鼠标/键盘"
        $btnSyncMouse.Background = "#252535"
        $btnSyncMouse.Foreground = "#c0c0d8"
        Set-Status "同步已停止。"
        return
    }
    $master = Resolve-SyncMaster
    if (-not $master) { [System.Windows.MessageBox]::Show("没有运行中的窗口。请先启动至少两个配置。","提示") | Out-Null; return }
    if (-not (Set-SyncMaster $master)) { return }
    $slaveProfiles = @($script:profiles | Where-Object { $_.id -ne $script:syncMaster.id -and (Is-Running $_) })
    $slavePorts = [int[]]@($slaveProfiles | ForEach-Object { [int]$_.debugPort })
    $slaveHwnds = [IntPtr[]]@($slaveProfiles | ForEach-Object { Get-ProfileWindowHandle $_ })
    if ($slavePorts.Count -eq 0) {
        [System.Windows.MessageBox]::Show("没有可同步的从控窗口。请至少再启动一个配置。","提示") | Out-Null
        return
    }
    $slaveWindowCount = @($slaveHwnds | Where-Object { $_ -ne [IntPtr]::Zero }).Count
    if ($slaveWindowCount -eq 0) {
        [System.Windows.MessageBox]::Show("找不到从控 Chrome 窗口句柄，请确认从控窗口可见后再开启同步。","提示") | Out-Null
        return
    }
    # Auto-detect Chrome UI height via window.screenY
    try {
        $masterPort = $script:syncMaster.debugPort
        $masterWsInfo = Invoke-RestMethod "http://127.0.0.1:$masterPort/json" -TimeoutSec 2 | Where-Object { $_.type -eq "page" } | Select-Object -First 1
        if ($masterWsInfo -and [MouseSync]::MasterHwnd -ne [IntPtr]::Zero) {
            [MouseSync]::TopOffset = [MouseSync]::CalcTopOffset($masterWsInfo.webSocketDebuggerUrl, [MouseSync]::MasterHwnd)
        }
    } catch { [MouseSync]::TopOffset = 88 }
    $mouseHookOk = [MouseSync]::StartHook()
    $kbdHookOk = [MouseSync]::StartKbdHook()
    if (-not $mouseHookOk -or -not $kbdHookOk) {
        [MouseSync]::StopAll()
        [System.Windows.MessageBox]::Show("无法安装鼠标/键盘 hook。鼠标错误码: $([MouseSync]::LastMouseHookError)  键盘错误码: $([MouseSync]::LastKeyboardHookError)","同步失败") | Out-Null
        return
    }
    $script:syncActive = $true
    [MouseSync]::StartRelay($slavePorts,$slaveHwnds)
    $btnSyncMouse.Content = "◉  同步中 ($($script:syncMaster.name))"
    $btnSyncMouse.Background = "#183d22"
    $btnSyncMouse.Foreground = "#7dd87d"
    Set-Status "整窗鼠标+键盘同步已开启，主控: $($script:syncMaster.name)，从控窗口: $slaveWindowCount/$($slavePorts.Count) 个。再次点击停止"
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.Add_Tick({ Refresh-UI; Refresh-WindowBadges 15 })
$timer.Start()
$window.Add_Closed({ $timer.Stop(); [MouseSync]::StopAll() })

Load-Config; Refresh-UI
$window.ShowDialog() | Out-Null
