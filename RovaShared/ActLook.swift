import Foundation

/// How a project looks, kept apart from its code: theme, accent colour, corners, buttons, text size and typeface.
/// Stored as one small file in the project (`gorunum.json`) so it syncs like everything else, and applied when
/// the page is shown: a style sheet and a small script are added to the bundled page. It works on any web
/// project - the page's own CSS variables, plain CSS or JavaScript that builds the page - and the project's
/// files are never rewritten. The writer can change the code freely; the look stays.
public struct ActLook: Codable, Equatable, Sendable {
    /// "light", "dark"; nil keeps the page's own.
    public var theme: String?
    /// "#rrggbb"
    public var accent: String?
    /// "sharp", "round"
    public var corners: String?
    /// "square", "pill"
    public var buttons: String?
    /// Text size in percent (85 ... 150); nil or 100 keeps the page's own.
    public var scale: Int?
    /// "serif", "rounded", "mono"
    public var font: String?

    public static let fileName = "gorunum.json"

    public init(theme: String? = nil, accent: String? = nil, corners: String? = nil, buttons: String? = nil, scale: Int? = nil, font: String? = nil) {
        self.theme = theme
        self.accent = accent
        self.corners = corners
        self.buttons = buttons
        self.scale = scale
        self.font = font
    }

    public var isDefault: Bool { theme == nil && accent == nil && corners == nil && buttons == nil && (scale == nil || scale == 100) && font == nil }

    public static func read(from files: [String: String]) -> ActLook {
        guard let text = files[fileName], let data = text.data(using: .utf8), let look = try? JSONDecoder().decode(ActLook.self, from: data) else { return ActLook() }
        return look
    }

    /// The file content for this look; nil when everything is default (the file is then removed).
    public func fileContent() -> String? {
        guard !isDefault else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The page with the look applied. Unchanged when the project has no look.
    public static func inject(_ html: String, files: [String: String]) -> String {
        let look = read(from: files)
        guard !look.isDefault else { return html }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(look), let config = String(data: data, encoding: .utf8) else { return html }
        let block = "<style id=\"wiqo-look-css\">\(css(for: look))</style><script id=\"wiqo-look-js\">\(script.replacingOccurrences(of: "__CONFIG__", with: config))</script>"
        if let close = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            var result = html
            result.insert(contentsOf: block, at: close.lowerBound)
            return result
        }
        return html + block
    }

    // MARK: Style sheet (what needs no measuring)

    private static func css(for look: ActLook) -> String {
        var rules = """
        html.wl-inv{filter:invert(1) hue-rotate(180deg)!important}
        html.wl-inv img,html.wl-inv video,html.wl-inv canvas,html.wl-inv picture,html.wl-inv iframe,html.wl-inv svg image,html.wl-inv [style*="url("]{filter:invert(1) hue-rotate(180deg)!important}
        """
        if look.corners == "sharp" { rules += "\n*,*::before,*::after{border-radius:0!important}" }
        if let font = look.font {
            let family: String
            switch font {
            case "serif": family = "Georgia,'Times New Roman',serif"
            case "mono": family = "ui-monospace,Menlo,'SF Mono',monospace"
            default: family = "ui-rounded,'SF Pro Rounded',system-ui,-apple-system,sans-serif"
            }
            rules += "\nbody,body *:not(code):not(pre):not(kbd):not(samp):not(i):not(svg):not([class*=\"icon\"]):not([class*=\"fa-\"]):not(.material-icons){font-family:\(family)!important}"
        }
        return rules
    }

    // MARK: Script (what needs the page's real colours and sizes)

    private static let script = #"""
    (function(){try{
    var L=__CONFIG__,root=document.documentElement,inv=false,obs=null,running=false,timer=null,seq=0;
    function parse(s){var m=/rgba?\(([^)]+)\)/.exec(s||'');if(!m)return null;var p=m[1].split(',').map(parseFloat);return{r:p[0],g:p[1],b:p[2],a:p.length>3?p[3]:1}}
    function lum(c){return(0.299*c.r+0.587*c.g+0.114*c.b)/255}
    function sat(c){var mx=Math.max(c.r,c.g,c.b),mn=Math.min(c.r,c.g,c.b);return mx===0?0:(mx-mn)/mx}
    function hex(h){var n=parseInt(h.slice(1),16);return{r:(n>>16)&255,g:(n>>8)&255,b:n&255}}
    function rgb(c){return'rgb('+Math.round(c.r)+','+Math.round(c.g)+','+Math.round(c.b)+')'}
    function flip(c){var r=1-c.r/255,g=1-c.g/255,b=1-c.b/255;function k(x){return Math.max(0,Math.min(1,x))*255}
      return{r:k(-0.574*r+1.430*g+0.144*b),g:k(0.426*r+0.430*g+0.144*b),b:k(0.426*r+1.430*g-0.856*b)}}
    var BTN='button,input[type=button],input[type=submit],input[type=reset],[role=button],[class*=btn],[class*=button],[class*=Button]';
    var HDR='header,nav,thead,[class*=header],[class*=navbar],[class*=hero],[class*=banner],[class*=primary],[class*=accent],[class*=active],[class*=selected],[class~=tab],[class*=tab-],[class*=-tab],[class~=tabs],[class*=badge],[class*=chip]';
    var SKIP=/^(SCRIPT|STYLE|LINK|META|HEAD|BR|SVG|PATH|G|IMG|CANVAS|VIDEO|OPTION|PICTURE|IFRAME)$/;
    function decideTheme(){
      if(!L.theme)return;
      root.classList.remove('wl-inv');root.style.removeProperty('background-color');
      var bg=null;[document.body,root].forEach(function(e){if(bg||!e)return;var c=parse(getComputedStyle(e).backgroundColor);if(c&&c.a>0.5)bg=c});
      var l=bg?lum(bg):1;
      inv=(L.theme==='dark'&&l>0.5)||(L.theme==='light'&&l<=0.5);
      if(inv){root.style.setProperty('background-color',bg?rgb(bg):'#fff','important');root.classList.add('wl-inv')}
    }
    function pass(){
      var acc=L.accent?hex(L.accent):null,fg=acc?(lum(acc)>0.6?{r:0,g:0,b:0}:{r:255,g:255,b:255}):null;
      var accP=acc?rgb(inv?flip(acc):acc):null,fgP=fg?rgb(inv?flip(fg):fg):null;
      if(acc){root.style.setProperty('accent-color',accP);['--accent','--primary','--brand','--color-primary','--primary-color','--accent-color','--main-color'].forEach(function(v){root.style.setProperty(v,accP)})}
      var key=JSON.stringify(L)+inv+seq,list=document.body?Array.prototype.slice.call(document.body.getElementsByTagName('*'),0,2500):[];
      var infos=[];
      list.forEach(function(el){
        if(SKIP.test(el.tagName)||el.__wk===key)return;
        var cs=getComputedStyle(el),r=el.getBoundingClientRect(),own=false;
        for(var n=el.firstChild;n;n=n.nextSibling){if(n.nodeType===3&&n.nodeValue.trim()){own=true;break}}
        infos.push({el:el,tag:el.tagName,bg:parse(cs.backgroundColor),col:parse(cs.color),bc:parse(cs.borderTopColor),bw:parseFloat(cs.borderTopWidth)||0,
          bi:cs.backgroundImage,fs:parseFloat(cs.fontSize)||16,rad:parseFloat(cs.borderTopLeftRadius)||0,w:r.width,h:r.height,own:own,
          btn:el.matches(BTN),hdr:el.matches(HDR),pos:cs.position});
      });
      infos.forEach(function(i){
        var el=i.el,s=el.style,colorful=i.bg&&i.bg.a>0.4&&sat(i.bg)>0.25;
        if(acc&&(i.btn||i.hdr||i.tag==='A')){
          if((i.btn||i.hdr)&&colorful){s.setProperty('background-color',accP,'important');if(i.bi&&i.bi!=='none')s.setProperty('background-image','none','important');s.setProperty('color',fgP,'important')}
          else if((!i.bg||i.bg.a<0.1)&&i.col&&sat(i.col)>0.35)s.setProperty('color',accP,'important');
          if(i.bw>0&&i.bc&&sat(i.bc)>0.25)s.setProperty('border-color',accP,'important');
        }
        var visible=(i.bg&&i.bg.a>0.05||i.bw>0)&&i.w>=24&&i.h>=16,boxed=visible&&i.w<(window.innerWidth-8);
        if(L.corners==='round'&&boxed&&!i.btn&&i.rad<14&&i.rad<Math.min(i.w,i.h)/2)s.setProperty('border-radius',Math.min(16,i.h/2)+'px','important');
        if(L.buttons&&(i.btn||i.tag==='BUTTON')&&visible)s.setProperty('border-radius',L.buttons==='pill'?'999px':'0','important');
        if(L.scale&&L.scale!==100&&i.own)s.setProperty('font-size',(i.fs*L.scale/100)+'px','important');
        el.__wk=key;
      });
    }
    function run(){
      if(running)return;running=true;if(obs)obs.disconnect();
      try{pass()}catch(e){}
      running=false;
      if(obs&&document.body)obs.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class']});
    }
    function later(){clearTimeout(timer);timer=setTimeout(run,150)}
    function start(){
      decideTheme();run();
      obs=new MutationObserver(function(ms){ms.forEach(function(m){if(m.type==='attributes')m.target.__wk=null});later()});
      if(document.body)obs.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class']});
      setTimeout(function(){decideTheme();run()},600);setTimeout(function(){decideTheme();run()},1600);
    }
    window.addEventListener('resize',function(){seq++;later()});
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);else start();
    }catch(e){}})();
    """#
}
