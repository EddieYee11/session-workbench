import SwiftUI
import ComCore

/// A small, isolated Canvas. No geometry/state writes are made from the frame loop.
struct AgentStageScene: View {
    let state: AgentStageState
    let elapsed: Double
    let moving: Bool
    let preview: String
    private let ink = Color(red: 0.17, green: 0.19, blue: 0.20)
    private let blue = Color(red: 0.52, green: 0.64, blue: 0.94)
    private let navy = Color(red: 0.18, green: 0.22, blue: 0.43)
    private let lime = Color(red: 0.79, green: 0.94, blue: 0.34)
    var body: some View {
        Canvas { context, size in
            let t = moving ? elapsed : 0
            let floor: CGFloat = 138
            let left = size.width * 0.22, right = size.width * 0.82
            // Corridor and delivery pedestal.
            var track = Path(); track.move(to: CGPoint(x: left + 22, y: floor)); track.addLine(to: CGPoint(x: right, y: floor))
            context.stroke(track, with: .color(lime.opacity(0.9)), style: StrokeStyle(lineWidth: 2, dash: [3, 6]))
            ellipse(&context, CGRect(x: right-34, y: floor-7, width: 68, height: 15), .gray.opacity(0.10))
            if state == .delivered {
                let glow = moving ? min(1, max(0, (t-1.55)*3)) : 1
                ellipse(&context, CGRect(x: right-37, y: floor-10, width: 74, height: 20), lime.opacity(glow*0.4))
            }
            round(&context, CGRect(x: right-27, y: floor-6, width: 54, height: 8), 4, .white)
            // Desk, computer, chair. These remain visually anchored while the courier moves.
            round(&context, CGRect(x: left-47, y: 111, width: 88, height: 6), 3, ink.opacity(0.18))
            line(&context, CGPoint(x:left-39,y:117), CGPoint(x:left-42,y:138), ink.opacity(0.22), 3)
            line(&context, CGPoint(x:left+32,y:117), CGPoint(x:left+35,y:138), ink.opacity(0.22), 3)
            round(&context, CGRect(x:left-41,y:67,width:45,height:34),5,ink)
            round(&context, CGRect(x:left-38,y:70,width:39,height:27),3,state == .failed ? Color.red.opacity(moving && t<0.7 ? 0.15+abs(sin(t*14))*0.3 : 0.22) : .white.opacity(0.93))
            line(&context, CGPoint(x:left-18,y:101), CGPoint(x:left-18,y:109), ink.opacity(0.5), 3)
            for i in 0..<3 {
                let shift: CGFloat = state == .working || state == .writing ? CGFloat(sin(t*5+Double(i))*3) : 0
                round(&context, CGRect(x:left-34,y:76+CGFloat(i)*6,width:CGFloat(14+i*5)+shift,height:2),1, i==0 ? lime : ink.opacity(0.17))
            }
            round(&context, CGRect(x:left+17,y:103,width:23,height:7),3,blue.opacity(0.5))
            line(&context, CGPoint(x:left+28,y:110), CGPoint(x:left+28,y:134), ink.opacity(0.2), 3)
            line(&context, CGPoint(x:left+18,y:135), CGPoint(x:left+38,y:135), ink.opacity(0.2), 3)
            // The icon's white/blue pair: the white partner stays by the desk,
            // while the blue partner in its beret works and carries the reply.
            whitePartner(&context, x: left-51, t: t)
            var x: CGFloat = left+27
            var y: CGFloat = 85
            var angle = 0.0
            var gait = 0.0
            if state == .delivered {
                // Lift the stack, accelerate out, decelerate at the pedestal, place it.
                let p = moving ? min(1,max(0,(t-0.28)/1.35)) : 1
                let back = moving ? min(1,max(0,(t-2.05)/0.7)) : 0
                let smooth = p*p*(3-2*p) * (1-back*back*(3-2*back))
                x += (right-left-27)*CGFloat(smooth)
                gait = (p>0 && p<1) || (back>0 && back<1) ? sin(t*23) : 0
                y = 91 - CGFloat(abs(gait)*5)
                angle = p>0 && p<1 ? 7*gait : 0
            } else if state == .idle {
                x = left+29; y = 120 - CGFloat(max(0,1-t/1.5)*sin(t*4)*2)
                angle = -8
            } else if state == .thinking { angle = sin(t*1.7)*5-6 }
            else if state == .searching { x += CGFloat(sin(t*2)*5); angle = sin(t*2)*6 }
            else if state == .working || state == .writing { y += CGFloat(sin(t*8)*1.4) }
            else if state == .failed { angle = moving ? sin(min(t,0.7)*25)*max(0,1-t)*9 : 4 }
            else if state == .review { angle = moving ? -9*max(0,1-t/0.45) : 0 }
            courier(&context, x: x, y: y, angle: angle, gait: gait, t: t)
            if state == .thinking {
                bubble(&context, x:left+66,y:35)
                for i in 0..<3 {
                    let light = !moving || Int(t*2.5)%3 == i
                    ellipse(&context, CGRect(x:left+50+CGFloat(i)*10,y:29,width:5,height:5), light ? lime : ink.opacity(0.15))
                }
            } else if state == .searching {
                let glass = CGPoint(x:x+28,y:y-5+CGFloat(sin(t*2))*3)
                context.stroke(Path(ellipseIn: CGRect(x:glass.x-12,y:glass.y-12,width:24,height:24)),with:.color(ink),lineWidth:2.5)
                line(&context, CGPoint(x:glass.x+8,y:glass.y+8),CGPoint(x:glass.x+17,y:glass.y+18),ink,3)
                line(&context,CGPoint(x:glass.x-7,y:glass.y+CGFloat(sin(t*3))*7),CGPoint(x:glass.x+7,y:glass.y+CGFloat(sin(t*3))*7),lime,2)
            } else if state == .review {
                let lift: CGFloat = moving ? CGFloat(max(0,1-t/0.45))*20 : 0
                round(&context,CGRect(x:x+16,y:76+lift,width:68,height:28),7,lime)
                context.draw(Text("等你拍板").font(.system(size:11,weight:.medium)).foregroundStyle(ink),at:CGPoint(x:x+50,y:90+lift))
            } else if state == .remembering || state == .calendar || state == .handoff {
                let symbol = state == .remembering ? "book.closed" : state == .calendar ? "calendar" : "paperplane"
                let dy = moving ? sin(t*2.6)*3 : 0
                context.draw(Image(systemName:symbol),in:CGRect(x:x+25,y:44+CGFloat(dy),width:25,height:25))
            } else if state == .idle {
                context.draw(Text("z z").font(.system(size:12,weight:.medium,design:.rounded)).foregroundStyle(ink.opacity(0.3)),at:CGPoint(x:x+35,y:91))
            } else if state == .offline || state == .waiting || state == .failed {
                context.draw(Image(systemName:state.symbol),in:CGRect(x:x+24,y:44,width:23,height:23))
            }
            if state == .delivered || (state == .idle && !preview.isEmpty) {
                let placed = state == .idle || !moving || t>1.65
                paper(&context,x:placed ? right : x+22,y:placed ? 122 : y+13, t:t, placed:placed)
                if placed {
                    let p = moving && state == .delivered ? min(1,max(0,(t-1.65)/0.35)) : 1
                    var card = context
                    card.opacity = p
                    let cy: CGFloat = 41 + CGFloat((1-p)*14)
                    round(&card,CGRect(x:right-65,y:cy-17,width:100,height:34),10,lime.opacity(0.95))
                    let label = preview.isEmpty ? "回复整理好了" : String(preview.prefix(9))
                    card.draw(Text(label).font(.system(size:10,weight:.medium)).foregroundStyle(ink),at:CGPoint(x:right-15,y:cy))
                }
            }
            if state == .working || state == .writing {
                for side in [-1.0,1.0] {
                    let tap = CGFloat(max(0,sin(t*14+side*2))*5)
                    round(&context,CGRect(x:left+2+CGFloat(side*7),y:105-tap,width:12,height:5),2,.white)
                }
            }
        }.accessibilityHidden(true)
    }
    private func courier(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, angle: Double, gait: Double, t: Double) {
        var ctx=c;ctx.translateBy(x:x,y:y);ctx.rotate(by:.degrees(angle))
        let sleepy = state == .idle
        ellipse(&ctx,CGRect(x:-24,y:sleepy ? 11 : 38,width:49,height:8),ink.opacity(0.08))
        if !sleepy {
            line(&ctx,CGPoint(x:-8,y:27),CGPoint(x:-12+CGFloat(gait*6),y:39),ink.opacity(0.5),4)
            line(&ctx,CGPoint(x:8,y:27),CGPoint(x:12-CGFloat(gait*6),y:39),ink.opacity(0.5),4)
            round(&ctx,CGRect(x:-15,y:13,width:30,height:20),9,blue.opacity(0.75))
        }
        round(&ctx,CGRect(x:-23,y:sleepy ? -13 : -28,width:47,height:sleepy ? 30 : 47),sleepy ? 14 : 20,blue)
        ellipse(&ctx,CGRect(x:-24,y:sleepy ? -19 : -35,width:47,height:18),navy)
        round(&ctx,CGRect(x:7,y:sleepy ? -23 : -39,width:5,height:10),2,navy)
        if !sleepy {
            var smile = Path(); smile.move(to:CGPoint(x:-4,y:4)); smile.addQuadCurve(to:CGPoint(x:5,y:4),control:CGPoint(x:1,y:9))
            ctx.stroke(smile,with:.color(ink),style:StrokeStyle(lineWidth:1.5,lineCap:.round))
        }
        let blink = sleepy || (moving && t.truncatingRemainder(dividingBy:4.1)>3.93)
        for eye in [-11.0,6.0] {
            round(&ctx,CGRect(x:CGFloat(eye),y:sleepy ? 0 : -10,width:4,height:blink ? 2 : 7),2,ink)
        }
        if state == .failed {
            let scratch = moving && t<1.2 ? CGFloat(sin(t*18))*3 : 0
            line(&ctx,CGPoint(x:13,y:22),CGPoint(x:26,y:-7+scratch),blue,5)
            round(&ctx,CGRect(x:20,y:-16+scratch,width:10,height:5),2,blue)
        }
        if state == .review || state == .delivered {
            line(&ctx,CGPoint(x:11,y:19),CGPoint(x:25,y:13),blue,5)
        }
    }
    private func whitePartner(_ c: inout GraphicsContext, x: CGFloat, t: Double) {
        var ctx = c
        let asleep = state == .idle
        let bob = moving && state.isBusy ? CGFloat(sin(t*2))*1.2 : 0
        ctx.translateBy(x:x,y:asleep ? 125 : 99+bob)
        ellipse(&ctx,CGRect(x:-18,y:asleep ? 5 : 32,width:38,height:6),ink.opacity(0.06))
        if !asleep {
            line(&ctx,CGPoint(x:-6,y:17),CGPoint(x:-8,y:31),ink.opacity(0.2),3)
            line(&ctx,CGPoint(x:6,y:17),CGPoint(x:8,y:31),ink.opacity(0.2),3)
        }
        let rect = CGRect(x:-18,y:asleep ? -15 : -29,width:36,height:asleep ? 22 : 44)
        round(&ctx,rect,asleep ? 11 : 16,.white)
        ctx.stroke(Path(roundedRect:rect,cornerRadius:16),with:.color(ink.opacity(0.08)),lineWidth:0.7)
        for eye in [-8.0,4.0] { round(&ctx,CGRect(x:CGFloat(eye),y:asleep ? -6 : -12,width:3,height:asleep ? 2 : 6),1.5,ink) }
        if state == .delivered {
            line(&ctx,CGPoint(x:16,y:7),CGPoint(x:24,y:-7 + CGFloat(sin(min(t,1.5)*8))*3),ink.opacity(0.15),3)
        }
    }
    private func paper(_ c: inout GraphicsContext, x: CGFloat,y:CGFloat,t:Double,placed:Bool) {
        let bounce = moving && placed ? CGFloat(sin(min(max(0,t-1.65),0.8)*10)*exp(-max(0,t-1.65)*5))*6 : 0
        for i in (0..<3).reversed() { round(&c,CGRect(x:x-14+CGFloat(i)*2,y:y-18+CGFloat(i)*3-bounce,width:27,height:22),3,i==0 ? .white : blue.opacity(0.7)) }
        for i in 0..<3 {line(&c,CGPoint(x:x-9,y:y-12+CGFloat(i)*4-bounce),CGPoint(x:x+6,y:y-12+CGFloat(i)*4-bounce),ink.opacity(0.2),1)}
    }
    private func bubble(_ c: inout GraphicsContext,x:CGFloat,y:CGFloat) {round(&c,CGRect(x:x-25,y:y-17,width:50,height:30),12,.white);ellipse(&c,CGRect(x:x-18,y:y+13,width:5,height:5),.white)}
    private func round(_ c: inout GraphicsContext,_ r:CGRect,_ radius:CGFloat,_ color:Color) {c.fill(Path(roundedRect:r,cornerRadius:radius),with:.color(color))}
    private func ellipse(_ c: inout GraphicsContext,_ r:CGRect,_ color:Color) {c.fill(Path(ellipseIn:r),with:.color(color))}
    private func line(_ c: inout GraphicsContext,_ a:CGPoint,_ b:CGPoint,_ color:Color,_ width:CGFloat) {var p=Path();p.move(to:a);p.addLine(to:b);c.stroke(p,with:.color(color),style:StrokeStyle(lineWidth:width,lineCap:.round))}
}
