import Foundation
import AppKit

/// The phone page: one self-contained HTML file (no CDNs), its manifest and a generated Home Screen icon.
enum WebUI {
    static func manifest(room: String) -> [String: Any] {
        ["name": room, "short_name": room, "start_url": "/", "scope": "/", "display": "standalone",
         "background_color": "#111215", "theme_color": "#1428A0",
         "icons": [["src": "/icon-180.png", "sizes": "180x180", "type": "image/png"],
                   ["src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"]]]
    }

    /// Samsung-blue square with a TV outline. Opaque, since iOS adds its own rounded mask.
    static func icon(size: Int) -> Data? {
        let s = CGFloat(size)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        if let bg = CGGradient(colorsSpace: space, colors: [rgb(0x3D5BFF), rgb(0x1428A0), rgb(0x070C3A)] as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
        }
        if let glow = CGGradient(colorsSpace: space, colors: [rgb(0x5B78FF, 0.55), rgb(0x5B78FF, 0)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s / 2, y: s * 0.55), startRadius: 0,
                                   endCenter: CGPoint(x: s / 2, y: s * 0.55), endRadius: s * 0.45, options: [])
        }
        let screen = CGRect(x: s * 0.19, y: s * 0.36, width: s * 0.62, height: s * 0.4)
        let path = CGPath(roundedRect: screen, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        if let fill = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.06)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: screen.maxY), end: CGPoint(x: 0, y: screen.minY), options: [])
        }
        ctx.resetClip()
        ctx.setStrokeColor(rgb(0xFFFFFF))
        ctx.setLineWidth(s * 0.05)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.move(to: CGPoint(x: s * 0.5, y: screen.minY - s * 0.02))
        ctx.addLine(to: CGPoint(x: s * 0.5, y: s * 0.27))
        ctx.move(to: CGPoint(x: s * 0.37, y: s * 0.25))
        ctx.addLine(to: CGPoint(x: s * 0.63, y: s * 0.25))
        ctx.strokePath()
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static let page = #"""
<!doctype html>
<html lang="en-GB" data-theme="{{THEME}}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="{{ROOM}}">
<meta name="theme-color" content="{{BAR}}">
<meta name="format-detection" content="telephone=no">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="icon" type="image/png" href="/icon-180.png">
<title>{{ROOM}}</title>
<style>
:root{--r:18px;--font:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;--round:ui-rounded,"SF Pro Rounded",var(--font);--mono:ui-monospace,"SF Mono",Menlo,monospace;
--accent-deep:#1428A0;--ps-blue:#0070D1}
:root[data-theme=dark]{color-scheme:dark;--bg:#111215;--card:#1B1C20;--raised:#26272D;--stroke:rgba(255,255,255,.06);--shadow:transparent;--primary:#fff;
--secondary:rgba(255,255,255,.55);--tertiary:rgba(255,255,255,.35);--accent:#5B78FF;--online:#34C759;--standby:#FFB020;--failure:#FF5A52;
--dim-track:rgba(255,255,255,.12);--bright-track:rgba(255,255,255,.9);--bezel:rgba(255,255,255,.18);--bar:rgba(17,18,21,.86);--swoff:#3A3B42;
--ps-deep:#00072D;--ps-mid:#0B1F6B;--ps-cyan:#3FE0FF;--ps-cyan-rgb:63,224,255;--ps-amber:#FFB020;--ps-glass:rgba(255,255,255,.06);--ps-edge:rgba(63,224,255,.18);
--ps-card:rgba(0,7,45,.55);--ps-muted:rgba(255,255,255,.45);--status:#111215}
:root[data-theme=light]{color-scheme:light;--bg:#F0F1F5;--card:#fff;--raised:#E7E9EF;--stroke:rgba(0,0,0,.07);--shadow:rgba(0,0,0,.05);--primary:#15161A;
--secondary:rgba(21,22,26,.62);--tertiary:rgba(21,22,26,.48);--accent:#2B47D9;--online:#1E9E47;--standby:#B86A00;--failure:#D3302A;
--dim-track:rgba(0,0,0,.08);--bright-track:#FFC53D;--bezel:#2A2C33;--bar:rgba(255,255,255,.88);--swoff:#C9CCD4;
--ps-deep:#E8F0FF;--ps-mid:#C6D8FF;--ps-cyan:#005BB5;--ps-cyan-rgb:0,91,181;--ps-amber:#B86A00;--ps-glass:rgba(0,112,209,.08);--ps-edge:rgba(0,112,209,.22);
--ps-card:rgba(255,255,255,.78);--ps-muted:rgba(21,22,26,.55);--status:#1428A0}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html{background:var(--bg)}
body{margin:0;min-height:100dvh;background:var(--bg);color:var(--primary);font:15px/1.35 var(--font);-webkit-font-smoothing:antialiased;
-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;overscroll-behavior-y:none;
padding:calc(env(safe-area-inset-top) + 10px) calc(env(safe-area-inset-right) + 16px) calc(env(safe-area-inset-bottom) + 96px) calc(env(safe-area-inset-left) + 16px)}
body::before{content:"";position:fixed;inset:0 0 auto 0;height:env(safe-area-inset-top);background:var(--status);z-index:40}
body.ps{background:linear-gradient(var(--ps-deep),var(--ps-mid) 55%,var(--ps-deep)) fixed}
#psbg{position:fixed;inset:0;width:100%;height:100%;pointer-events:none;z-index:0;display:none}
body.ps #psbg{display:block}
#app{position:relative;z-index:1}
button{font:inherit;color:inherit;border:0;background:none;padding:0;cursor:pointer;touch-action:manipulation}
button:disabled{cursor:default}
.i{width:22px;height:22px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
.i.fill{fill:currentColor;stroke:none}
.sp,.grow{flex:1;min-width:0}
small{font-size:12px;color:var(--secondary)}
.note{font-size:12px;color:var(--tertiary);margin:2px 4px 0;line-height:1.4}
.label{font-size:12px;font-weight:600;letter-spacing:1.2px;text-transform:uppercase;color:var(--secondary);display:flex;align-items:center;gap:8px;margin:4px 4px 0}
.dot{width:8px;height:8px;border-radius:50%;background:var(--tertiary);display:inline-block;flex:none}
.dot.accent{background:var(--accent)}.dot.online{background:var(--online)}.dot.standby{background:var(--standby)}
.stack{display:flex;flex-direction:column;gap:14px}
.card{background:var(--card);border:1px solid var(--stroke);border-radius:var(--r);padding:16px;box-shadow:0 2px 8px var(--shadow);display:flex;flex-direction:column;gap:12px}
.card-h{display:flex;align-items:center;gap:8px;font-size:15px}
.card-h .i{width:18px;height:18px;color:var(--secondary)}
.card-h b{font-weight:600}
.off{opacity:.5;pointer-events:none}
.press{transition:transform .09s ease,opacity .09s ease}
.press:active,.press.held{transform:scale(.95);opacity:.65}
.btn{background:var(--raised);border-radius:14px;min-height:52px;display:flex;align-items:center;justify-content:center;gap:8px;font-weight:600;font-size:15px;padding:0 16px}
.btn.deep{background:var(--accent-deep);color:#fff}
.btn.wide{width:100%}
.btn.sq{width:64px;min-height:52px;padding:0}
.btn .i{width:20px;height:20px}
.spin{width:18px;height:18px;border-radius:50%;border:2px solid currentColor;border-right-color:transparent;animation:spin .8s linear infinite;display:inline-block;flex:none;opacity:.8}
@keyframes spin{to{transform:rotate(360deg)}}
/* header */
.top{display:flex;align-items:center;gap:12px;padding:6px 2px 12px}
.badge{width:40px;height:40px;border-radius:50%;background:var(--accent-deep);color:#fff;display:grid;place-items:center;flex:none}
.badge .i{width:19px;height:19px}
.top h1{font-size:21px;font-weight:700;margin:0;letter-spacing:-.2px}
.top small{display:flex;align-items:center;gap:6px;margin-top:1px}
.round{width:46px;height:46px;border-radius:50%;background:var(--card);border:1px solid var(--stroke);display:grid;place-items:center;color:var(--secondary)}
.round.on{color:var(--accent)}
/* glance */
.glance{display:flex;gap:8px;margin-bottom:10px}
.pill{background:var(--card);border-radius:13px;min-height:46px;display:flex;align-items:center;gap:8px;padding:0 12px;min-width:0}
.pill b{font-size:15px;font-weight:600;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pill small{font-size:11px;color:var(--tertiary);display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pill.m b{font-size:13px}
.pill .em{font-size:20px}
.pill.dash{color:var(--tertiary);opacity:.6;padding:0 16px}
.pill.m{flex:1}
.ars{background:#EF0107;color:#fff;font-size:10px;font-weight:800;border-radius:5px;padding:4px 5px;flex:none}
.live{background:#EF0107;color:#fff;font-size:10px;font-weight:800;border-radius:99px;padding:3px 7px;flex:none;letter-spacing:.4px}
.pill.wash{flex-direction:column;justify-content:center;gap:1px;padding:0 9px;min-width:52px;background:color-mix(in srgb,var(--card) 60%,transparent);position:relative}
.pill.wash .i{width:18px;height:18px;color:var(--tertiary)}
.pill.wash small{color:var(--secondary);font-weight:500;font-variant-numeric:tabular-nums}
.pill.wash .bell{position:absolute;top:5px;right:8px;width:9px;height:9px;color:var(--accent)}
.wbar{width:100%;background:var(--card);border-radius:13px;padding:9px 12px;display:flex;align-items:center;gap:10px;margin-bottom:10px;text-align:left}
.wicon{width:30px;height:30px;border-radius:8px;display:grid;place-items:center;color:#fff;background:var(--accent);flex:none}
.wicon .i{width:16px;height:16px}
.wbar.paused .wicon{background:var(--standby)}.wbar.finished .wicon{background:var(--online)}
.wrow{display:flex;justify-content:space-between;gap:8px;align-items:baseline}
.wrow b{font-size:13px;font-weight:600}.wrow small{font-size:12px;font-variant-numeric:tabular-nums}
.segs{display:flex;gap:3px;margin-top:6px}
.seg{height:5px;border-radius:3px;background:var(--dim-track);overflow:hidden}
.seg i{display:block;height:100%;background:var(--accent);border-radius:3px}
.wbar.paused .seg i{background:var(--standby)}
/* tabs */
.tabs{position:fixed;left:0;right:0;bottom:0;z-index:30;display:flex;justify-content:space-around;padding:6px calc(env(safe-area-inset-right) + 8px) calc(env(safe-area-inset-bottom) + 6px) calc(env(safe-area-inset-left) + 8px);
background:var(--bar);-webkit-backdrop-filter:blur(20px) saturate(1.6);backdrop-filter:blur(20px) saturate(1.6);border-top:1px solid var(--stroke)}
.tabs button{flex:1;display:flex;flex-direction:column;align-items:center;gap:3px;padding:6px 0 4px;color:var(--secondary);font-size:11px;font-weight:600;border-radius:12px}
.tabs button .i{width:25px;height:25px}
.tabs button.sel{color:var(--accent)}
/* now */
.tvwrap{padding:0 10px}
.screen{position:relative;height:200px;border-radius:10px;border:3px solid var(--bezel);background:linear-gradient(#0A0B10,#14172A);color:#fff;
display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px}
.screen.lit{box-shadow:0 8px 24px color-mix(in srgb,var(--accent) 30%,transparent)}
.screen-top{position:absolute;top:10px;right:10px;display:flex;align-items:center;gap:10px}
.onoff{font-size:11px;font-weight:700;letter-spacing:1px;color:rgba(255,255,255,.35)}
.onoff.on{color:#5B78FF}
.screen .i.big{width:34px;height:34px;color:#5B78FF}.screen .i.dim{width:28px;height:28px;color:rgba(255,255,255,.35)}
.screen-title{font-size:18px;font-weight:600}
.btn.pill-on{min-height:40px;border-radius:12px;background:var(--accent-deep);color:#fff;font-size:14px;padding:0 22px}
.stand{display:flex;justify-content:space-between;padding:6px 30px 0}
.stand i{width:34px;height:2px;background:var(--bezel);transform:rotate(-18deg)}.stand i+i{transform:rotate(18deg)}
.switch{width:51px;height:31px;border-radius:99px;background:var(--raised);position:relative;flex:none;transition:background .15s}
.switch::after{content:"";position:absolute;top:2px;left:2px;width:27px;height:27px;border-radius:50%;background:#fff;box-shadow:0 2px 4px rgba(0,0,0,.3);transition:transform .15s}
.switch.on{background:var(--accent)}.switch.on::after{transform:translateX(20px)}
.screen .switch{background:rgba(255,255,255,.18)}.screen .switch.on{background:var(--accent-deep)}
.caption p{margin:4px 4px 0;font-size:14px;color:var(--secondary)}
.dpad{position:relative;width:236px;height:236px;margin:6px auto 2px;border-radius:50%;background:var(--raised);border:1px solid var(--stroke)}
.dpad .arrow{position:absolute;width:76px;height:76px;display:grid;place-items:center;border-radius:50%}
.dpad .arrow .i{width:26px;height:26px;stroke-width:2.6}
.dpad .up{top:0;left:80px}.dpad .down{bottom:0;left:80px}.dpad .left{left:0;top:80px}.dpad .right{right:0;top:80px}
.dpad .ok{position:absolute;left:68px;top:68px;width:100px;height:100px;border-radius:50%;background:color-mix(in srgb,var(--accent) 20%,transparent);color:var(--accent);font-weight:700;font-size:18px}
.row2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.media{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}
.media .btn{min-height:46px}.media .i{width:18px;height:18px}
.vol{display:flex;align-items:center;gap:10px}
.volnum{min-width:44px;text-align:center;font-size:22px;font-weight:700;font-variant-numeric:tabular-nums}
.chips{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.chip{background:var(--raised);border-radius:12px;min-height:50px;display:flex;align-items:center;gap:8px;padding:0 12px;font-size:14px;font-weight:500;text-align:left}
.chip span{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.chip .i{width:17px;height:17px}
.chip.sel{background:var(--accent-deep);color:#fff;font-weight:600}
.rowbtn{display:flex;align-items:center;gap:12px;min-height:54px;text-align:left;width:100%}
.rowbtn .ico{width:40px;height:40px;border-radius:10px;background:var(--raised);display:grid;place-items:center;flex:none}
.rowbtn .ico .i{width:19px;height:19px}
.rowbtn b{font-size:15px;font-weight:600;display:block}.rowbtn .chev{width:16px;height:16px;color:var(--tertiary)}
/* apps */
.apps{display:grid;grid-template-columns:repeat(3,1fr);gap:18px 10px}
.app{display:flex;flex-direction:column;align-items:center;gap:8px;font-size:13px;color:var(--secondary)}
.tile{position:relative;width:68px;height:68px;border-radius:17px;background:var(--c);color:#fff;font-weight:800;font-size:25px;display:grid;place-items:center}
.tile.long{font-size:16px}
.tile.big{width:64px;height:64px;border-radius:15px}
.tile .run{position:absolute;top:-4px;right:-4px;width:13px;height:13px;border-radius:50%;background:var(--online);border:2.5px solid var(--card)}
.tile .spin{position:absolute;inset:auto;width:22px;height:22px}
/* scenes */
.scenes{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.scene{position:relative;min-height:128px;border-radius:var(--r);padding:14px;color:#fff;text-align:left;display:flex;flex-direction:column;overflow:hidden;
background:radial-gradient(circle at 100% 0,rgba(255,255,255,.18),transparent 70%),linear-gradient(135deg,var(--a),var(--b));
border:1px solid rgba(255,255,255,.1);box-shadow:0 6px 16px color-mix(in srgb,var(--a) 28%,transparent)}
.scene.cur{border:1.5px solid rgba(255,255,255,.5)}
.scene.dim{opacity:.45}
:root[data-theme=light] .scene.dim{opacity:.7;filter:saturate(.3)}
.scene-top{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:auto}
.sicon{width:40px;height:40px;border-radius:50%;background:rgba(255,255,255,.16);display:grid;place-items:center}
.sicon .i{width:20px;height:20px}
.scene b{font-size:17px;font-weight:700;margin-top:14px}
.scene small{color:rgba(255,255,255,.75);font-size:12px;font-weight:500}
.sbadge .i{width:22px;height:22px}
.track{display:flex;flex-direction:column;gap:9px;padding-left:12px;border-left:2px solid var(--tc)}
.track.solo{padding-left:0;border:0}
.step{display:flex;gap:10px;align-items:flex-start}
.step .i,.step .spin{width:18px;height:18px;margin-top:1px}
.step b{font-size:14px;font-weight:500;display:block}
.step.pending b{color:var(--secondary)}
.st-done{color:var(--online)}.st-warning{color:var(--standby)}.st-failed{color:var(--failure)}.st-skipped,.st-pending{color:var(--tertiary)}
.step small.warning{color:var(--standby)}.step small.failed{color:var(--failure)}
.link{color:var(--accent);font-size:14px;font-weight:600;padding:6px 0 6px 10px}
/* lights */
.presets{display:grid;grid-template-columns:repeat(auto-fill,minmax(62px,1fr));gap:8px}
.preset{background:var(--card);border:1px solid var(--stroke);border-radius:14px;padding:12px 3px 8px;display:flex;flex-direction:column;align-items:center;gap:7px;
font-size:11px;font-weight:600;line-height:1.15;text-align:center;box-shadow:0 1px 4px var(--shadow);min-height:86px;
-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;touch-action:manipulation}
.preset.act{border:1.5px solid var(--accent);font-weight:700}
.preset.empty{background:transparent;border:1.5px dashed var(--stroke);box-shadow:none;color:var(--secondary)}
.preset.empty .sw{border:1.5px dashed var(--stroke);box-shadow:none}
.sw{position:relative;width:36px;height:36px;border-radius:50%;display:grid;place-items:center;flex:none;box-shadow:0 0 8px color-mix(in srgb,var(--g) 50%,transparent)}
.sw::before{content:"";position:absolute;inset:0;border-radius:50%;background:rgba(0,0,0,var(--dim));box-shadow:inset 0 0 0 1px rgba(127,127,127,.3)}
.sw .spin{position:relative;color:#fff}
.sw .tick{position:absolute;right:-5px;bottom:-5px;width:17px;height:17px;border-radius:50%;background:var(--accent);color:#fff;display:grid;place-items:center;border:2px solid var(--card)}
.sw .tick .i{width:10px;height:10px;stroke-width:3.5}
.sw .tick.warn{background:var(--standby)}.sw .tick.fail{background:var(--failure)}
.result{font-size:13px;color:var(--standby);margin:0 4px}.result.failed{color:var(--failure)}
.lhead{display:flex;align-items:center;gap:12px}
.glow{width:40px;height:40px;border-radius:50%;display:grid;place-items:center;flex:none;color:var(--secondary);background:color-mix(in srgb,var(--tertiary) 14%,transparent)}
.glow.on{color:var(--g);background:color-mix(in srgb,var(--g) 22%,transparent);box-shadow:0 0 14px color-mix(in srgb,var(--g) 55%,transparent)}
.glow .i{width:19px;height:19px}
.lhead b{font-size:15px;font-weight:600;display:block}
.slider-row{display:flex;align-items:center;gap:12px}
.slider-row .i{width:18px;height:18px;color:var(--secondary)}
input[type=range]{-webkit-appearance:none;appearance:none;flex:1;height:36px;background:transparent;margin:0}
input[type=range]::-webkit-slider-runnable-track{height:8px;border-radius:99px;background:var(--track);box-shadow:inset 0 0 0 1px var(--stroke)}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:28px;height:28px;border-radius:50%;background:#fff;margin-top:-10px;box-shadow:0 2px 6px rgba(0,0,0,.4)}
input[type=range]::-moz-range-track{height:8px;border-radius:99px;background:var(--track)}
input[type=range]::-moz-range-thumb{width:28px;height:28px;border-radius:50%;background:#fff;border:0}
.swatches{display:flex;justify-content:space-between;gap:6px}
.swatch{width:32px;height:32px;border-radius:50%;background:var(--c);box-shadow:inset 0 0 0 1px rgba(0,0,0,.1)}
.swatch.sel{box-shadow:0 0 0 2.5px var(--card),0 0 0 4.5px var(--primary)}
.bulbs{display:flex;flex-direction:column;gap:10px}
.card.bulb{padding:12px 14px;gap:6px}
.card.bulb.dead{opacity:.6}
/* ps5 */
.ps-head{display:flex;align-items:center;justify-content:space-between;margin:4px 2px 0}
.ps-head h1{font:800 24px/1.1 var(--round);margin:0;text-shadow:0 0 12px rgba(var(--ps-cyan-rgb),.35)}
.mono{font-family:var(--mono);font-size:11px;color:var(--ps-muted)}
.neon{display:flex;align-items:center;gap:7px;font:800 11px var(--round);letter-spacing:2px;color:var(--nc);padding:6px 12px;border-radius:99px;
border:1px solid color-mix(in srgb,var(--nc) 80%,transparent);background:color-mix(in srgb,var(--nc) 12%,transparent);box-shadow:0 0 10px color-mix(in srgb,var(--nc) 55%,transparent)}
.neon i{width:7px;height:7px;border-radius:50%;background:var(--nc);box-shadow:0 0 5px var(--nc)}
.neon.dim{border-color:color-mix(in srgb,var(--nc) 30%,transparent);background:color-mix(in srgb,var(--nc) 6%,transparent);box-shadow:none}.neon.dim i{box-shadow:none}
.ncard{background:var(--ps-card);-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px);border:1px solid var(--ps-edge);border-radius:var(--r);padding:16px;display:flex;flex-direction:column;gap:12px}
.nlabel{font-size:12px;font-weight:700;letter-spacing:1.6px;color:var(--ps-cyan)}
.ps-switch{width:100%;min-height:62px;border-radius:16px;padding:0 16px;display:flex;align-items:center;gap:12px;color:#fff;text-align:left;
background:linear-gradient(90deg,#0070D1,#2A5BFF);border:1px solid rgba(var(--ps-cyan-rgb),.35);box-shadow:0 0 14px rgba(0,112,209,.6)}
.ps-switch:disabled{opacity:.5;box-shadow:none}
.ps-switch b{font-size:15px;font-weight:700;display:block}.ps-switch small{color:rgba(255,255,255,.75);font-size:12px}
.art{width:64px;height:64px;border-radius:13px;flex:none;overflow:hidden;display:grid;place-items:center;border:1px solid var(--ps-edge);
background:linear-gradient(135deg,var(--ps-mid),rgba(0,112,209,.6));color:var(--ps-muted);position:relative}
.art img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.art.small{width:44px;height:44px;border-radius:9px}
.playing{display:flex;gap:14px;align-items:center}
.playing b{font-size:17px;font-weight:700;display:block}
.title-row{display:flex;gap:12px;align-items:center}
.title-row .t{display:flex;justify-content:space-between;gap:8px;font-size:14px;font-weight:600}
.title-row .t span:last-child{font:700 13px var(--round);color:var(--ps-cyan);flex:none}
.pbar{height:5px;border-radius:3px;background:var(--ps-glass);margin-top:7px;overflow:hidden}
.pbar i{display:block;height:100%;border-radius:3px;background:linear-gradient(90deg,#0070D1,var(--ps-cyan));box-shadow:0 0 6px var(--ps-cyan)}
.pw{display:flex;align-items:center;gap:12px}
.pw .ico{width:40px;height:40px;border-radius:10px;background:var(--ps-glass);display:grid;place-items:center;flex:none}
.pw .ico .i{width:19px;height:19px}
.pw b{font-size:15px;font-weight:600;display:block}
.btn.ps{background:var(--ps-blue);color:#fff;min-height:46px;font-size:14px}.btn.ps.glass{background:var(--ps-glass);color:var(--primary)}
.amber{color:var(--ps-amber);font-size:12px}
body.ps .note{color:var(--ps-muted)}
/* pair, sheet, toast */
.pair{min-height:calc(100dvh - 120px);display:flex;align-items:center;justify-content:center}
.pair-card{width:100%;max-width:380px;text-align:center;display:flex;flex-direction:column;gap:14px;align-items:center}
.pair-card img{width:84px;height:84px;border-radius:20px;box-shadow:0 8px 24px rgba(20,40,160,.35)}
.pair-card h1{margin:6px 0 0;font-size:26px}
.pair-card p{margin:0;color:var(--secondary);font-size:15px}
#code{width:100%;font:700 34px var(--mono);letter-spacing:12px;text-align:center;padding:14px 0 14px 12px;border-radius:16px;border:1px solid var(--stroke);
background:var(--card);color:var(--primary);outline:none;-webkit-user-select:text;user-select:text}
#code:focus{border-color:var(--accent)}
.msg{min-height:20px;font-size:14px;color:var(--failure)!important}
.offline{position:sticky;top:calc(env(safe-area-inset-top) + 4px);z-index:20;background:var(--standby);color:#000;font-size:13px;font-weight:600;border-radius:12px;padding:10px 14px;margin-bottom:10px}
.sheet{position:fixed;inset:0;z-index:60;display:flex;flex-direction:column;justify-content:flex-end}
.sheet-bg{position:absolute;inset:0;background:rgba(0,0,0,.4)}
.sheet-card{position:relative;margin:0 10px calc(env(safe-area-inset-bottom) + 10px);background:var(--card);border-radius:22px;padding:18px;display:flex;flex-direction:column;gap:10px;
animation:up .18s ease-out}
@keyframes up{from{transform:translateY(40px);opacity:0}}
.sheet-card b{font-size:17px;text-align:center}.sheet-card p{margin:0 0 6px;text-align:center;color:var(--secondary);font-size:13px}
.sheet-card input.name{width:100%;font-family:inherit;font-size:17px;font-weight:600;padding:12px 14px;border-radius:14px;border:1px solid var(--stroke);
background:var(--raised);color:var(--primary);outline:none;-webkit-user-select:text;user-select:text}
.sheet-card input.name:focus{border-color:var(--accent)}
.btn.slot{justify-content:space-between;text-align:left;font-weight:500}.btn.danger{color:var(--failure)}
.btn.edit{min-height:42px;font-size:14px;margin-top:8px}
.toast{position:fixed;left:16px;right:16px;bottom:calc(env(safe-area-inset-bottom) + 84px);z-index:50;background:var(--primary);color:var(--bg);border-radius:14px;padding:12px 16px;
font-size:14px;font-weight:500;opacity:0;transform:translateY(10px);transition:opacity .2s,transform .2s;pointer-events:none}
.toast.show{opacity:1;transform:none}
#hap{position:fixed;left:0;bottom:0;width:1px;height:1px;opacity:0;overflow:hidden;pointer-events:none}
[hidden]{display:none!important}
</style>
</head>
<body>
<canvas id="psbg"></canvas>
<div id="app" hidden>
  <div id="offline" class="offline" hidden>Can't reach the Mac. Is it awake, with the app open, on this Wi-Fi?</div>
  <header class="top" id="top"></header>
  <div id="glance"></div>
  <div id="washerbar"></div>
  <main id="view" class="stack"></main>
  <nav class="tabs" id="tabs"></nav>
</div>
<div id="pair" class="pair" hidden>
  <div class="pair-card">
    <img src="/icon-180.png" alt="">
    <h1>Pair this device</h1>
    <p>On your Mac, open the Samsung TV panel in the menu bar, click <b>···</b> and choose <b>Pair a phone…</b> Then enter the 6-digit code it shows.</p>
    <input id="code" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" maxlength="6" placeholder="······" aria-label="Pairing code">
    <button class="btn wide deep press" id="pairbtn">Pair</button>
    <p id="pairmsg" class="msg"></p>
    <p class="note">Works on your home Wi-Fi only. Nothing leaves your network.</p>
  </div>
</div>
<div id="sheet" class="sheet" hidden></div>
<div id="toast" class="toast"></div>
<label id="hap" aria-hidden="true"><input type="checkbox" switch tabindex="-1"></label>
<script>
"use strict";
const $ = s => document.querySelector(s);
const I = {
  tv:'<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8M12 17v4"/>',
  power:'<path d="M12 3v9"/><path d="M6.3 6.3a8 8 0 1 0 11.4 0"/>',
  sparkles:'<path d="M11 3l1.9 5.1L18 10l-5.1 1.9L11 17l-1.9-5.1L4 10l5.1-1.9z"/><path d="M19 15l.8 2.2 2.2.8-2.2.8L19 21l-.8-2.2-2.2-.8 2.2-.8z"/>',
  grid:'<rect x="4" y="4" width="7" height="7" rx="2"/><rect x="13" y="4" width="7" height="7" rx="2"/><rect x="4" y="13" width="7" height="7" rx="2"/><rect x="13" y="13" width="7" height="7" rx="2"/>',
  bulb:'<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.6 10.8c.7.6 1.1 1.3 1.1 2.2h5c0-.9.4-1.6 1.1-2.2A6 6 0 0 0 12 3z"/>',
  bulbs:'<path d="M7 18h4M8 21h2"/><path d="M9 6a4.5 4.5 0 0 0-2.7 8.1c.5.4.8 1 .8 1.9h3.8c0-.9.3-1.5.8-1.9A4.5 4.5 0 0 0 9 6z"/><path d="M14.5 4.5a4.5 4.5 0 0 1 3.2 7.7c-.5.4-.7 1-.7 1.8M15 18h2"/>',
  gamepad:'<path d="M6.5 7h11A4.5 4.5 0 0 1 22 11.5V14a3.5 3.5 0 0 1-6.3 2.1L14.5 15h-5l-1.2 1.1A3.5 3.5 0 0 1 2 14v-2.5A4.5 4.5 0 0 1 6.5 7z"/><path d="M7.5 10v3M6 11.5h3"/><path d="M15.5 10.5h.01M17.5 12.5h.01"/>',
  dpad:'<path d="M9.5 3h5v6.5H21v5h-6.5V21h-5v-6.5H3v-5h6.5z"/>',
  home:'<path d="M4 11l8-7 8 7"/><path d="M6 9.5V20h12V9.5"/>',
  back:'<path d="M9 14L4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
  up:'<path d="M6 15l6-6 6 6"/>', down:'<path d="M6 9l6 6 6-6"/>', left:'<path d="M15 6l-6 6 6 6"/>', right:'<path d="M9 6l6 6-6 6"/>',
  speaker:'<path d="M11 5L6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
  mute:'<path d="M11 5L6 9H3v6h3l5 4z"/><path d="M16 9.5l5 5M21 9.5l-5 5"/>',
  minus:'<path d="M5 12h14"/>', plus:'<path d="M12 5v14M5 12h14"/>',
  check:'<path d="M5 12.5l4.5 4.5L19 7"/>', x:'<path d="M6 6l12 12M18 6L6 18"/>',
  warn:'<path d="M12 8v5M12 16.5h.01"/>',
  circle:'<circle cx="12" cy="12" r="8" stroke-dasharray="3 3"/>',
  okc:'<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.7 2.7L16 9.8"/>',
  warnc:'<path d="M12 3l9.5 17h-19z"/><path d="M12 10v4M12 17h.01"/>',
  failc:'<circle cx="12" cy="12" r="9"/><path d="M9 9l6 6M15 9l-6 6"/>',
  skipc:'<circle cx="12" cy="12" r="9"/><path d="M8 12h8"/>',
  hdmi:'<path d="M3 8h18v5l-2.5 3h-13L3 13z"/><path d="M7 11h10"/>',
  source:'<rect x="3" y="7" width="13" height="10" rx="2"/><path d="M8 4h11a2 2 0 0 1 2 2v8"/>',
  washer:'<rect x="4" y="3" width="16" height="18" rx="2.5"/><circle cx="12" cy="13" r="4.5"/><path d="M7.5 6.5h2"/>',
  bell:'<path d="M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z"/>',
  pause:'<path d="M9 5v14M15 5v14"/>',
  play:'<path d="M7 5l12 7-12 7z"/>', stop:'<rect x="6" y="6" width="12" height="12" rx="1.5"/>',
  rew:'<path d="M11 6l-7 6 7 6zM20 6l-7 6 7 6z"/>', ff:'<path d="M13 6l7 6-7 6zM4 6l7 6-7 6z"/>',
  film:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 4v16M17 4v16M3 9h4M3 15h4M17 9h4M17 15h4"/>',
  moon:'<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>',
  sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  sunmin:'<circle cx="12" cy="12" r="4"/><path d="M12 5v.01M12 19v.01M5 12h.01M19 12h.01M7 7h.01M17 17h.01M7 17h.01M17 7h.01"/>',
  therm:'<path d="M10 4a2 2 0 0 1 4 0v10a4 4 0 1 1-4 0z"/><path d="M12 9v7"/>',
  tvbox:'<rect x="2" y="4" width="14" height="10" rx="1.5"/><path d="M6 18h6M9 14v4"/><rect x="18" y="8" width="4" height="10" rx="1"/>',
  refresh:'<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  link:'<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
};
const ic = (n, c='') => `<svg class="i ${c}" viewBox="0 0 24 24" aria-hidden="true">${I[n]||I.sparkles}</svg>`;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const spin = '<span class="spin"></span>';
const TABS = [['now','tv','Now'],['apps','grid','Apps'],['scenes','sparkles','Scenes'],['lights','bulb','Lights'],['ps5','gamepad','PS5']];

let S = null, tab = 'now', paired = null, offline = false, timer = null, inflight = false, holdUntil = 0, sheetActions = [];
try { const t = (location.hash || '').slice(1) || localStorage.getItem('tab'); if (TABS.some(x => x[0] === t)) tab = t; } catch (e) {}

function haptic() { try { $('#hap').click(); } catch (e) {} }
function toast(text) {
  const t = $('#toast'); t.textContent = text; t.classList.add('show');
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove('show'), 3200);
}
function setHTML(el, html) { if (el.__html !== html) { el.innerHTML = html; el.__html = html; } }

async function api(path, body) {
  const opts = body === undefined ? {cache: 'no-store', credentials: 'same-origin'}
    : {method: 'POST', cache: 'no-store', credentials: 'same-origin', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)};
  const r = await fetch(path, opts);
  const json = (r.headers.get('content-type') || '').includes('json') ? await r.json() : null;
  if (r.status === 401 && path !== '/api/pair') { showPair(); throw new Error('unpaired'); }
  return {status: r.status, json};
}
function schedule(ms) { clearTimeout(timer); timer = setTimeout(poll, ms); }
async function poll() {
  if (document.hidden) return;
  if (inflight) { schedule(300); return; }
  inflight = true;
  try {
    const {status, json} = await api('/api/state?focus=' + tab);
    if (status === 200) { setOffline(false); showApp(); S = json; render(); }
  } catch (e) { if (e.message !== 'unpaired') setOffline(true); }
  inflight = false;
  if (paired) schedule(offline ? 4000 : 2000);
}
function setOffline(v) { offline = v; $('#offline').hidden = !v; }
async function act(path, body = {}, quiet = false) {
  haptic();
  try {
    const {status, json} = await api(path, body);
    if (status >= 400 && json && json.error && !quiet) toast(json.error);
  } catch (e) { if (e.message !== 'unpaired') toast("Couldn't reach the Mac."); }
  schedule(120); setTimeout(() => { if (!inflight) poll(); }, 1300);
}
function key(k) { haptic(); api('/api/tv/key', {key: k}).then(r => { if (r.status >= 400 && r.json) toast(r.json.error); }).catch(() => {}); }

// MARK: pairing
function showPair() {
  paired = false; clearTimeout(timer);
  $('#app').hidden = true; $('#pair').hidden = false; document.body.classList.remove('ps');
  setTimeout(() => $('#code').focus(), 50);
}
function showApp() { if (paired !== true) { paired = true; $('#pair').hidden = true; $('#app').hidden = false; } }
async function pair() {
  const code = $('#code').value.replace(/\D/g, '');
  if (code.length !== 6) { $('#pairmsg').textContent = 'Enter all 6 digits.'; return; }
  $('#pairbtn').disabled = true; $('#pairmsg').textContent = '';
  try {
    const {status, json} = await api('/api/pair', {code});
    if (status === 200) { haptic(); $('#code').value = ''; paired = null; poll(); }
    else { $('#pairmsg').textContent = (json && json.error) || 'Pairing failed.'; $('#code').select(); }
  } catch (e) { $('#pairmsg').textContent = "Couldn't reach the Mac."; }
  $('#pairbtn').disabled = false;
}
$('#pairbtn').addEventListener('click', pair);
$('#code').addEventListener('input', e => { e.target.value = e.target.value.replace(/\D/g, '').slice(0, 6); if (e.target.value.length === 6) pair(); });

// MARK: render
function render() {
  if (!S) return;
  const root = document.documentElement;
  if (root.dataset.theme !== S.theme) {
    root.dataset.theme = S.theme;
    document.querySelector('meta[name=theme-color]').content = S.theme === 'dark' ? '#111215' : '#1428A0';
  }
  document.body.classList.toggle('ps', tab === 'ps5');
  setHTML($('#top'), header());
  setHTML($('#glance'), glance());
  setHTML($('#washerbar'), washerBar());
  setHTML($('#tabs'), TABS.map(([id, icon, title]) => `<button class="press ${tab === id ? 'sel' : ''}" data-tab="${id}">${ic(icon)}<span>${title}</span></button>`).join(''));
  if (tab === 'lights' && Date.now() < holdUntil) return;
  const views = {now: nowView, apps: appsView, scenes: scenesView, lights: lightsView, ps5: ps5View};
  setHTML($('#view'), views[tab]());
  ps.run(tab === 'ps5');
}

function header() {
  const tv = S.tv, on = tv.power === 'on';
  const dot = on ? 'online' : tv.power === 'standby' || tv.waking ? 'standby' : '';
  return `<div class="badge">${ic('tv')}</div>
  <div class="grow"><h1>${esc(S.room)}</h1><small><span class="dot ${dot}"></span>${esc(tv.status)} · Samsung · Tizen</small></div>
  <button class="round press ${on ? 'on' : ''}" data-act="tv.power" aria-label="${on ? 'Turn off the TV' : 'Turn on the TV'}">${ic('power')}</button>`;
}

function glance() {
  const w = S.weather, m = S.match, wa = S.washer;
  let h = '<div class="glance">';
  h += w ? `<div class="pill" title="${esc(w.place + ': ' + w.summary)}"><span class="em">${w.emoji}</span><div><b>${w.temp}°</b>${w.range ? `<small>${esc(w.range)}</small>` : ''}</div></div>`
         : '<div class="pill dash">–</div>';
  h += m ? `<div class="pill m" title="${esc(m.title)}"><span class="ars">ARS</span><div class="grow"><b>${esc(m.headline)}</b><small>${esc(m.detail)}</small></div>${m.live ? `<span class="live">${esc(m.live)}</span>` : ''}</div>`
         : '<div class="pill m dash">–</div>';
  if (wa && wa.chip) h += `<button class="pill wash press" data-act="washer.chip">${ic('washer')}${wa.chip.notify ? ic('bell', 'fill bell') : ''}<small>${esc(wa.chip.short)}</small></button>`;
  return h + '</div>';
}

function washerBar() {
  const b = S.washer && S.washer.bar;
  if (!b) return '';
  const total = b.segments.reduce((a, s) => a + s[0], 0) || 1;
  const body = b.segments.length ? `<div class="segs">${b.segments.map(s => `<div class="seg" style="flex:${s[0] / total}"><i style="width:${Math.round(s[1] * 100)}%"></i></div>`).join('')}</div>`
    : `<small>${esc(b.note || '')}</small>`;
  return `<button class="wbar ${b.kind} press" data-act="washer.bar"><span class="wicon">${ic(b.kind === 'paused' ? 'pause' : 'washer')}</span>
    <div class="grow"><div class="wrow"><b>${esc(b.title)}</b><small>${esc(b.trailing)}</small></div>${body}</div></button>`;
}

function tile(a, cls = '') {
  return `<div class="tile ${cls} ${a.short.length > 3 ? 'long' : ''}" style="--c:#${a.colour}">${esc(a.short)}${a.running ? '<i class="run"></i>' : ''}</div>`;
}

function nowView() {
  const tv = S.tv, on = tv.power === 'on', lit = on || tv.waking;
  let screen = on ? (tv.app ? `${tile(tv.app, 'big')}<div class="screen-title">${esc(tv.app.name)}</div>` : `${ic('tv', 'big')}<div class="screen-title">TV on</div>`)
    : `${ic('power', 'dim')}<button class="btn pill-on press" data-act="tv.power">${tv.waking ? 'Turning on…' : 'Turn on'}</button>`;
  let h = `<section class="tvwrap"><div class="screen ${on ? 'lit' : ''}">
    <div class="screen-top"><span class="onoff ${on ? 'on' : ''}">${on ? 'ON' : tv.waking ? '…' : 'OFF'}</span>
    <button class="switch ${lit ? 'on' : ''}" data-act="tv.power" aria-label="TV power"></button></div>${screen}</div>
    <div class="stand"><i></i><i></i></div></section>
    <div class="caption"><div class="label"><span class="dot ${on ? 'accent' : ''}"></span>Now on screen</div><p>${esc(tv.caption)}</p></div>`;
  const arrow = (d, k) => `<button class="arrow ${d} press" data-key="${k}" data-repeat aria-label="${d}">${ic(d)}</button>`;
  h += `<div class="card ${on ? '' : 'off'}">
    <div class="card-h">${ic('dpad')}<b>Remote</b><span class="sp"></span><span class="dot ${tv.remoteReady ? 'online' : 'standby'}"></span><small>${esc(tv.remote)}</small></div>
    <div class="dpad">${arrow('up', 'KEY_UP')}${arrow('down', 'KEY_DOWN')}${arrow('left', 'KEY_LEFT')}${arrow('right', 'KEY_RIGHT')}
      <button class="ok press" data-key="KEY_ENTER">OK</button></div>
    <div class="row2"><button class="btn press" data-key="KEY_RETURN">${ic('back')}Back</button><button class="btn press" data-key="KEY_HOME">${ic('home')}Home</button></div>
    <div class="media">${[['rew', 'KEY_REWIND', 'Rewind'], ['play', 'KEY_PLAY', 'Play'], ['pause', 'KEY_PAUSE', 'Pause'], ['ff', 'KEY_FF', 'Fast forward']]
      .map(([i, k, l]) => `<button class="btn press" data-key="${k}" aria-label="${l}">${ic(i, i === 'play' || i === 'rew' || i === 'ff' ? 'fill' : '')}</button>`).join('')}</div></div>`;
  const vol = tv.volume == null ? '' : tv.muted ? 'Muted' : '';
  h += `<div class="card ${on ? '' : 'off'}">
    <div class="card-h">${ic('speaker')}<b>TV audio</b><span class="sp"></span><small>${vol}</small></div>
    <div class="vol"><button class="btn sq press" data-key="KEY_MUTE" aria-label="Mute">${ic(tv.muted ? 'mute' : 'speaker')}</button><span class="sp"></span>
      <button class="btn sq press" data-key="KEY_VOLDOWN" data-repeat aria-label="Volume down">${ic('minus')}</button>
      ${tv.volume == null ? '' : `<span class="volnum">${tv.volume}</span>`}
      <button class="btn sq press" data-key="KEY_VOLUP" data-repeat aria-label="Volume up">${ic('plus')}</button></div>
    <p class="note">${tv.volume == null ? "The TV doesn't report its volume level; each press sends one step. Hold to repeat." : 'Level from SmartThings (can lag a little). Hold − or + to repeat.'}</p></div>`;
  const active = tv.inputs.find(i => i.id === tv.input);
  const row = (icon, title, sub, k) => `<button class="rowbtn press" data-key="${k}"><span class="ico">${ic(icon)}</span><div class="grow"><b>${title}</b><small>${sub}</small></div>${ic('right', 'chev')}</button>`;
  h += `<div class="card ${on ? '' : 'off'}"><div class="card-h">${ic('hdmi')}<b>Inputs</b><span class="sp"></span><small>${active ? 'On ' + esc(active.name) : ''}</small></div>`;
  if (tv.smartThings && tv.inputs.length) {
    h += `<div class="chips">${tv.inputs.map(i => `<button class="chip press ${i.id === tv.input ? 'sel' : ''}" data-act="tv.input" data-id="${esc(i.id)}">
      ${tv.inputBusy === i.id ? spin : ic(i.kind === 'ps5' || i.kind === 'console' ? 'gamepad' : i.kind === 'hdmi' ? 'hdmi' : 'tv')}<span>${esc(i.label)}</span>${i.id === tv.input ? ic('check') : ''}</button>`).join('')}</div>`;
    h += row('source', 'Source menu', 'Opens the TV input menu', 'KEY_SOURCE');
  } else {
    h += row('source', 'Source', 'Opens the TV input menu', 'KEY_SOURCE') + row('gamepad', 'HDMI', 'Cycles through HDMI inputs (PS5 etc.)', 'KEY_HDMI');
  }
  if (tv.notice) h += `<p class="note">${esc(tv.notice)}</p>`;
  return h + '</div>';
}

function appsView() {
  const tv = S.tv, on = tv.power === 'on';
  return `<div class="label">Apps</div><div class="card ${on ? '' : 'off'}"><div class="apps">${tv.apps.map(a =>
    `<button class="app press" data-act="tv.app" data-app="${a.key}">${tile(a).replace('</div>', tv.launching === a.key ? spin + '</div>' : '</div>')}<span>${esc(a.name)}</span></button>`).join('')}</div></div>
    <p class="note">${on ? 'A green dot means the app is open, on screen or in the background. Only apps this Mac knows about appear.' : 'Turn the TV on to open an app.'}</p>`;
}

function stepIcon(s) {
  return s === 'running' ? spin : `<span class="st-${s}">${ic({pending: 'circle', done: 'okc', warning: 'warnc', failed: 'failc', skipped: 'skipc'}[s])}</span>`;
}

function scenesView() {
  const sc = S.scenes, cur = sc.current;
  let h = `<div class="label">Scenes</div><div class="scenes">${sc.list.map(s => {
    const isCur = cur && cur.id === s.id;
    let badge = '';
    if (isCur) badge = !cur.finished ? spin : ic(cur.failed ? 'failc' : cur.warned ? 'warnc' : 'okc');
    return `<button class="scene press ${isCur ? 'cur' : ''} ${sc.running && !isCur ? 'dim' : ''}" data-act="scene.run" data-id="${s.id}" ${sc.running ? 'disabled' : ''} style="--a:#${s.from};--b:#${s.to}">
      <div class="scene-top"><span class="sicon">${ic(s.icon)}</span><span class="sbadge">${badge}</span></div><b>${esc(s.name)}</b><small>${esc(s.subtitle)}</small></button>`;
  }).join('')}</div>`;
  if (cur) {
    const scene = sc.list.find(s => s.id === cur.id) || {from: '5b78ff'};
    const tracks = {};
    cur.steps.forEach(st => (tracks[st.track] = tracks[st.track] || []).push(st));
    const tone = cur.failed ? 'failed' : cur.warned ? 'warning' : 'done';
    h += `<div class="card"><div class="card-h"><b>${esc(cur.name)}</b><span class="sp"></span>${cur.finished ? `<button class="link" data-act="scene.clear">Clear</button>` : `<small>${esc(cur.summary)}</small>`}</div>
      ${cur.finished ? `<div class="st-${tone}" style="font-size:14px;font-weight:600">${esc(cur.summary)}</div>` : ''}
      ${Object.values(tracks).map(steps => `<div class="track ${cur.tracks > 1 ? '' : 'solo'}" style="--tc:#${scene.from}b3">${steps.map(st =>
        `<div class="step ${st.status}">${stepIcon(st.status)}<div><b>${esc(st.label)}</b>${st.detail ? `<small class="${st.status}">${esc(st.detail)}</small>` : ''}</div></div>`).join('')}</div>`).join('')}
      ${cur.tracks > 1 ? '<p class="note" style="margin:0">Each bar runs at the same time.</p>' : ''}</div>`;
  }
  const opens = sc.list.filter(s => s.app).map(s => `${esc(s.name)} opens ${esc(s.app)}`).join('. ');
  return h + `<p class="note">${opens ? opens + '. ' : ''}Change apps, automations and Alexa triggers from the Mac.</p>`;
}

function swatchStyle(p) {
  const cols = p.swatches.map(c => c ? '#' + c : 'var(--swoff)');
  const same = cols.every(c => c === cols[0]);
  const bg = cols.length < 2 || same ? `radial-gradient(circle at 25% 25%,${cols[0] || 'gray'},color-mix(in srgb,${cols[0] || 'gray'} 70%,transparent) 90%)`
    : `conic-gradient(from -90deg,${cols.join(',')},${cols[0]})`;
  const dim = ((1 - p.level) * (1 - p.level) * 0.55).toFixed(3);
  return `background:${bg};--dim:${dim};--g:${cols[0] || 'transparent'}`;
}

function slider(kind, idx, value, min, max, track) {
  return `<input type="range" min="${min}" max="${max}" value="${value}" data-slide="${kind}" data-index="${idx}" style="--track:${track}" aria-label="${kind}">`;
}

function lightsView() {
  const L = S.lights;
  let h = '<div class="label">Lights</div>';
  if (L.state === 'unavailable') return h + `<div class="card"><div class="card-h"><b>Lights unavailable</b></div><small>${esc(L.message)}</small><p class="note" style="margin:0">Use Retry in the Mac's Lights tab.</p></div>`;
  if (L.state === 'loading') return h + `<div class="card"><div class="card-h">${spin}<small>Looking for the lights…</small></div></div>`;
  if (L.state === 'empty') return h + '<div class="card"><small>No lights found.</small></div>';
  h += `<div class="presets">${L.presets.map(p => {
    const r = L.result && L.result.id === p.id && L.result.text ? L.result : null;
    const badge = L.busy === p.id ? spin : r ? `<span class="tick ${r.failed ? 'fail' : 'warn'}">${ic('warn')}</span>` : p.active ? `<span class="tick">${ic('check')}</span>` : '';
    const slot = (L.slots || []).findIndex(s => s && s.id === p.id);
    return `<button class="preset press ${p.active ? 'act' : ''}" data-act="light.preset" data-id="${esc(p.id)}" ${slot >= 0 ? `data-hold="${slot}"` : ''} ${L.busy ? 'disabled' : ''} title="${esc(p.summary)}">
      <span class="sw" style="${swatchStyle(p)}">${badge}</span><span>${esc(p.name)}</span></button>`;
  }).join('')}${(L.slots || []).map((p, i) => p ? '' : `<button class="preset press empty" data-act="preset.pick" data-slot="${i}" ${L.busy ? 'disabled' : ''}>
      <span class="sw">${ic('plus')}</span><span>Save current</span></button>`).join('')}</div>`;
  h += `<button class="btn wide press edit" data-act="preset.edit">Rename or clear presets</button>`;
  if (L.result && L.result.text) h += `<p class="result ${L.result.failed ? 'failed' : ''}">${esc(L.result.text)}</p>`;
  const warmCool = 'linear-gradient(90deg,#ffb861,#cce5ff)';
  const bright = 'linear-gradient(90deg,var(--dim-track),var(--bright-track))';
  const allOn = L.anyOn;
  h += `<div class="card ${L.enabled ? '' : 'off'}"><div class="lhead"><span class="glow ${allOn ? 'on' : ''}" style="--g:var(--accent)">${ic('bulbs')}</span>
    <div class="grow"><b>All lights</b><small>${esc(L.subtitle)}</small></div><button class="switch ${allOn ? 'on' : ''}" data-act="light.power" data-index="" data-on="${!allOn}" aria-label="All lights"></button></div>
    <div class="slider-row">${ic('sunmin')}${slider('brightness', '', L.brightness, 1, 100, bright)}</div>
    <div class="slider-row">${ic('therm')}${slider('temp', '', L.temp, 0, 100, warmCool)}</div>
    <div class="swatches">${L.swatches.map(s => `<button class="swatch press" style="--c:#${s.hex}" data-act="light.colour" data-hex="${s.hex}" data-index="" aria-label="${esc(s.name)}"></button>`).join('')}</div></div>`;
  h += `<div class="bulbs">${L.bulbs.map(b => `<div class="card bulb ${b.reachable ? '' : 'dead off'}"><div class="lhead"><span class="glow ${b.on ? 'on' : ''}" style="--g:#${b.glow}">${ic('bulb')}</span>
    <div class="grow"><b>${esc(b.label)}</b><small>${esc(b.subtitle)}</small></div><button class="switch ${b.on ? 'on' : ''}" data-act="light.power" data-index="${b.index}" data-on="${!b.on}" aria-label="${esc(b.label)}"></button></div>
    ${b.reachable ? `<div class="slider-row">${ic('sunmin')}${slider('brightness', b.index, b.brightness, 1, 100, bright)}</div>` : ''}</div>`).join('')}</div>`;
  if (L.error) h += `<p class="result">${esc(L.error)}</p>`;
  return h + '<p class="note">Controlled over the local network (Tuya, no cloud).</p>';
}

function ps5View() {
  const P = S.ps5;
  const pill = !P.polled ? ['SEARCHING', 'var(--secondary)', true] : P.status === 'on' ? ['ONLINE', 'var(--ps-cyan)', false]
    : P.status === 'rest' ? ['REST MODE', 'var(--ps-amber)', false] : ['OFFLINE', 'var(--ps-muted)', true];
  let h = `<div class="ps-head"><div><h1>PlayStation 5</h1><span class="mono">${esc(P.name)} · ${esc(P.host)}</span></div>
    <span class="neon ${pill[2] ? 'dim' : ''}" style="--nc:${pill[1]}"><i></i>${pill[0]}</span></div>
    <button class="ps-switch press" data-act="tv.input" data-id="HDMI2" ${P.tvOn ? '' : 'disabled'}>${ic('tvbox')}<div class="grow"><b>Switch TV to PS5</b><small>${esc(P.switchNote)}</small></div>${ic('right')}</button>`;
  if (P.psn === 'ready') {
    h += `<div class="ncard"><div class="card-h"><span class="nlabel">NOW PLAYING</span><span class="sp"></span>${P.onlineId ? `<span class="mono">${esc(P.onlineId)}</span>` : ''}</div>
      <div class="playing"><div class="art">${ic('gamepad')}${P.art ? `<img src="/api/art/now?t=${encodeURIComponent(P.playing || '')}" alt="" onerror="this.remove()">` : ''}</div>
      <div class="grow"><b>${esc(P.playing || (P.online ? 'Online, not in a game' : 'Not playing'))}</b><small>${esc(P.caption)}</small></div></div>
      ${P.psnError ? `<div class="amber">${esc(P.psnError)}</div>` : ''}</div>`;
    h += `<div class="ncard"><span class="nlabel">MOST PLAYED</span>${P.top.length ? P.top.map((t, i) => `<div class="title-row"><div class="art small">${ic('gamepad')}${t.art ? `<img src="/api/art/top/${i}?t=${encodeURIComponent(t.name)}" alt="" onerror="this.remove()">` : ''}</div>
      <div class="grow"><div class="t"><span>${esc(t.name)}</span><span>${esc(t.time)}</span></div><div class="pbar"><i style="width:${Math.max(3, Math.round(t.fraction * 100))}%"></i></div></div></div>`).join('')
      : '<small>No play time on record yet.</small>'}</div>`;
  } else if (P.psn === 'loading') {
    h += `<div class="ncard"><div class="card-h">${spin}<small>Connecting to PSN…</small></div></div>`;
  } else {
    h += `<div class="ncard"><b>${P.psn === 'connect' ? 'Connect PSN' : 'PSN not connected'}</b>${P.psnError ? `<div class="amber">${esc(P.psnError)}</div>` : ''}
      <small>Set up PSN from the PS5 tab on the Mac to see what you're playing here.</small></div>`;
  }
  const on = P.status === 'on', reach = P.polled && P.status !== 'off';
  h += `<div class="ncard"><div class="pw"><span class="ico">${ic('power')}</span><div class="grow"><b>Power</b><small>${P.busy ? (on ? 'Going to rest mode…' : 'Waking…') : reach ? (on ? 'On' : 'In rest mode') : 'Not answering on the network'}</small></div>
    <button class="btn ps press ${on ? 'glass' : ''}" data-act="ps5.power" data-on="${!on}" ${!reach || P.busy ? 'disabled style="opacity:.5"' : ''}>${P.busy ? spin : ''}${on ? 'Rest mode' : 'Turn on'}</button></div>
    ${P.error ? `<div class="amber">${esc(P.error)}</div>` : ''}</div>
    <p class="note">Status comes from the console on the local network. PSN details refresh at most every minute.</p>`;
  return h;
}

// MARK: sheets
function openSheet(inner, actions = []) {
  sheetActions = actions;
  const el = $('#sheet');
  el.innerHTML = `<div class="sheet-bg" data-act="sheet.close"></div><div class="sheet-card">${inner}</div>`;
  el.hidden = false;
}
function sheet(title, text, actions) {
  openSheet(`<b>${esc(title)}</b><p>${esc(text)}</p>
    ${actions.map((a, i) => `<button class="btn wide press ${a.deep ? 'deep' : ''}" data-sheet="${i}">${esc(a.label)}</button>`).join('')}
    <button class="btn wide press" data-act="sheet.close">Cancel</button>`, actions);
}
function closeSheet() { $('#sheet').hidden = true; sheetActions = []; editSlot = null; }

// Preset slots: the sheet is not redrawn by polling, so the name field keeps what is typed.
let editSlot = null;
function slotsSheet() {
  editSlot = null;
  const rows = (S.lights.slots || []).map((p, i) => `<button class="btn wide press slot" data-act="preset.pick" data-slot="${i}">
    <span>${i + 1} · ${p ? esc(p.name) : "Empty"}</span>${ic("right")}</button>`).join("");
  openSheet(`<b>Edit presets</b><p>Pick a slot to save how the lights look now, or to rename or clear it. Tip: press and hold a saved preset to get here directly.</p>${rows}
    <button class="btn wide press" data-act="sheet.close">Done</button>`);
}
function slotSheet(i) {
  const p = (S.lights.slots || [])[i];
  editSlot = i;
  openSheet(`<b>Slot ${i + 1}</b><p>${p ? "Now: " + esc(p.name) : "Empty"}</p>
    <input id="pname" class="name" maxlength="40" autocomplete="off" enterkeyhint="done" aria-label="Preset name" value="${esc(p ? p.name : "Preset " + (i + 1))}">
    <button class="btn wide press deep" data-act="preset.save">${p ? "Replace with the lights now" : "Save the lights now"}</button>
    ${p ? `<button class="btn wide press" data-act="preset.rename">Rename</button><button class="btn wide press danger" data-act="preset.clear">Clear slot</button>` : ""}
    <button class="btn wide press" data-act="preset.edit">Back</button>`);
}
const presetName = () => ($("#pname") ? $("#pname").value : "").trim();
async function presetCall(path, body, done) {
  haptic();
  const buttons = [...document.querySelectorAll("#sheet button")];
  buttons.forEach(b => { b.disabled = true; });
  try {
    const {status, json} = await api(path, body);
    if (status < 400) { closeSheet(); toast((json && json.note) || done(json || {})); }
    else { toast((json && json.error) || "That did not work. Try again."); buttons.forEach(b => { b.disabled = false; }); }
  } catch (e) {
    if (e.message !== "unpaired") toast("No answer. Try again.");
    buttons.forEach(b => { b.disabled = false; });
  }
  schedule(120);
}

// MARK: input
const handlers = {
  'tv.power': () => act('/api/tv/power', {on: !(S.tv.power === 'on' || S.tv.waking)}),
  'tv.app': el => act('/api/tv/app', {app: el.dataset.app}),
  'tv.input': el => act('/api/tv/input', {id: el.dataset.id}),
  'scene.run': el => act('/api/scenes/run', {id: el.dataset.id}),
  'scene.clear': () => act('/api/scenes/clear'),
  'light.preset': el => act('/api/lights/preset', {id: el.dataset.id}),
  'light.power': el => { holdUntil = Date.now() + 1500; el.classList.toggle('on'); act('/api/lights/power', {on: el.dataset.on === 'true', index: idx(el)}); },
  'light.colour': el => act('/api/lights/colour', {hex: el.dataset.hex, index: idx(el)}),
  'ps5.power': el => act('/api/ps5/power', {on: el.dataset.on === 'true'}),
  'washer.chip': () => {
    const c = S.washer.chip;
    if (c.free) return sheet(c.sentence, S.washer.detail, []);
    sheet(c.sentence, S.washer.detail + '. Notifications appear on the Mac.', [
      {label: "This one's mine", deep: true, run: () => act('/api/washer/claim')},
      {label: c.notify ? "Stop telling me when it's free" : "Tell me when it's free", run: () => act('/api/washer/notify-free', {on: !c.notify})},
    ]);
  },
  'washer.bar': () => {
    const b = S.washer.bar;
    sheet(b.title, S.washer.detail, [{label: b.kind === 'finished' ? 'Dismiss' : 'Not mine', run: () => act('/api/washer/unclaim')}]);
  },
  'sheet.close': closeSheet,
  'preset.edit': () => slotsSheet(),
  'preset.pick': el => slotSheet(Number(el.dataset.slot)),
  'preset.save': el => {
    el.innerHTML = spin + "Reading the lights…";
    presetCall("/api/presets/save", {slot: editSlot, name: presetName()}, j => `Saved ${j.name || "the preset"}.`);
  },
  'preset.rename': () => presetCall("/api/presets/rename", {slot: editSlot, name: presetName()}, j => `Renamed to ${j.name || presetName()}.`),
  'preset.clear': el => {
    if (el.dataset.armed !== "1") { el.dataset.armed = "1"; el.textContent = "Tap again to clear"; return; }
    const slot = editSlot;
    presetCall("/api/presets/clear", {slot}, () => `Cleared slot ${slot + 1}.`);
  },
};
const idx = el => el.dataset.index === '' ? null : Number(el.dataset.index);

document.addEventListener('touchstart', () => {}, {passive: true});
document.addEventListener('click', e => {
  const el = e.target.closest('[data-act],[data-key],[data-tab],[data-sheet]');
  if (!el || el.disabled || el.closest('.off')) return;
  if (el.dataset.tab) {
    haptic(); tab = el.dataset.tab;
    try { localStorage.setItem('tab', tab); history.replaceState(null, '', '#' + tab); } catch (err) {}
    window.scrollTo(0, 0); render(); schedule(0); return;
  }
  if (el.dataset.sheet !== undefined) { const a = sheetActions[Number(el.dataset.sheet)]; closeSheet(); if (a) a.run(); return; }
  if (el.dataset.key) { if (el.dataset.repeat === undefined) key(el.dataset.key); return; }
  const h = handlers[el.dataset.act]; if (h) h(el);
});

let rep = null;
function stopRepeat() { if (rep) { clearTimeout(rep.t); clearInterval(rep.i); rep.el.classList.remove('held'); rep = null; } }
document.addEventListener('pointerdown', e => {
  const el = e.target.closest('[data-repeat]');
  if (!el || el.closest('.off')) return;
  stopRepeat();
  el.classList.add('held'); key(el.dataset.key);
  rep = {el, t: setTimeout(() => { rep.i = setInterval(() => key(el.dataset.key), 180); }, 450)};
});
['pointerup', 'pointercancel', 'pointerleave'].forEach(n => document.addEventListener(n, stopRepeat));

// Press and hold a saved preset (500 ms) for its slot sheet; a normal tap still applies it.
const HOLD_MS = 500;
let hold = null, heldAt = 0;
function stopHold() { if (hold) { clearTimeout(hold.t); hold = null; } }
document.addEventListener('pointerdown', e => {
  const el = e.target.closest('[data-hold]');
  if (!el || el.disabled) return;
  stopHold();
  const slot = Number(el.dataset.hold);
  hold = {x: e.clientX, y: e.clientY, t: setTimeout(() => { hold = null; heldAt = Date.now(); haptic(); slotSheet(slot); }, HOLD_MS)};
});
document.addEventListener('pointermove', e => { if (hold && Math.hypot(e.clientX - hold.x, e.clientY - hold.y) > 10) stopHold(); });
['pointerup', 'pointercancel'].forEach(n => document.addEventListener(n, stopHold));
// The finger lifting after a hold must not also apply the preset or close the sheet that just opened.
document.addEventListener('click', e => {
  if (heldAt && Date.now() - heldAt < 700) { heldAt = 0; e.preventDefault(); e.stopImmediatePropagation(); }
}, true);
document.addEventListener('contextmenu', e => { if (e.target.closest('[data-hold]')) e.preventDefault(); });

const slideLast = {};
function sendSlide(el, final) {
  const k = el.dataset.slide + '|' + el.dataset.index, now = Date.now();
  if (!final && now - (slideLast[k] || 0) < 160) return;
  slideLast[k] = now;
  api('/api/lights/' + el.dataset.slide, {pct: Number(el.value), index: idx(el)}).catch(() => {});
}
document.addEventListener('input', e => { if (e.target.dataset && e.target.dataset.slide) { holdUntil = Date.now() + 4000; sendSlide(e.target, false); } });
document.addEventListener('change', e => { if (e.target.dataset && e.target.dataset.slide) { holdUntil = Date.now() + 2500; sendSlide(e.target, true); haptic(); } });
document.addEventListener('keydown', e => {
  if (e.key !== "Enter" || !e.target || e.target.id !== "pname") return;
  e.preventDefault();
  const b = $("#sheet [data-act=\"preset.rename\"]") || $("#sheet [data-act=\"preset.save\"]");
  if (b && !b.disabled) b.click();
});
document.addEventListener('visibilitychange', () => { if (!document.hidden && paired !== false) poll(); });

// MARK: PS5 backdrop, ported from the Mac panel: synthwave floor and drifting △ ○ ✕ □
const ps = (() => {
  const c = $('#psbg'), ctx = c.getContext('2d');
  let on = false, last = 0;
  const pal = ['64,224,176', '255,90,122', '106,168,255', '229,138,255'];
  function frame(ts) {
    if (!on) return;
    requestAnimationFrame(frame);
    if (ts - last < 33) return;
    last = ts;
    const dpr = window.devicePixelRatio || 1, w = innerWidth, h = innerHeight;
    if (c.width !== w * dpr || c.height !== h * dpr) { c.width = w * dpr; c.height = h * dpr; }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, w, h);
    const t = ts / 1000, cyan = getComputedStyle(document.documentElement).getPropertyValue('--ps-cyan-rgb').trim() || '63,224,255';
    const hz = h * 0.58, fh = h - hz;
    ctx.fillStyle = `rgba(${cyan},.35)`; ctx.fillRect(0, hz - 1, w, 2);
    ctx.save(); ctx.beginPath(); ctx.rect(0, hz, w, fh); ctx.clip();
    const g = ctx.createLinearGradient(0, hz, 0, h); g.addColorStop(0, `rgba(${cyan},.03)`); g.addColorStop(1, `rgba(${cyan},.22)`);
    ctx.strokeStyle = g; ctx.lineWidth = .8; ctx.beginPath();
    for (let i = -12; i <= 12; i++) { ctx.moveTo(w / 2, hz); ctx.lineTo(w / 2 + i * w / 7, h); }
    const phase = (t * 0.12) % 1;
    for (let i = 0; i < 14; i++) { const z = (i + phase) / 14, y = hz + fh * z * z; ctx.moveTo(0, y); ctx.lineTo(w, y); }
    ctx.stroke(); ctx.restore();
    for (let i = 0; i < 10; i++) {
      const seed = i * 1.618, speed = 0.008 + 0.004 * (i % 3);
      const y = h * (1 - ((seed * 0.37 + t * speed) % 1.15)), x = w * ((seed * 0.53) % 1) + Math.sin(t * 0.2 + seed) * 14, s = 10 + (i % 4) * 4;
      ctx.beginPath();
      switch (i % 4) {
        case 0: ctx.moveTo(x, y - s / 2); ctx.lineTo(x + s / 2, y + s / 2.4); ctx.lineTo(x - s / 2, y + s / 2.4); ctx.closePath(); break;
        case 1: ctx.arc(x, y, s / 2, 0, Math.PI * 2); break;
        case 2: ctx.moveTo(x - s / 2, y - s / 2); ctx.lineTo(x + s / 2, y + s / 2); ctx.moveTo(x + s / 2, y - s / 2); ctx.lineTo(x - s / 2, y + s / 2); break;
        default: ctx.rect(x - s / 2, y - s / 2, s, s);
      }
      ctx.shadowColor = `rgba(${pal[i % 4]},.6)`; ctx.shadowBlur = 6; ctx.lineWidth = 2.5; ctx.strokeStyle = `rgba(${pal[i % 4]},.3)`; ctx.stroke();
      ctx.shadowBlur = 0; ctx.lineWidth = 1.2; ctx.strokeStyle = `rgba(${pal[i % 4]},.22)`; ctx.stroke();
    }
  }
  return {run(v) { if (v && !on) { on = true; requestAnimationFrame(frame); } else if (!v) on = false; }};
})();

poll();
</script>
</body>
</html>
"""#
}
