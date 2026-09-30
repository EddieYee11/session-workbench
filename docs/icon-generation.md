# Com! 双伙伴图标

2026-10-01，为 Com! 的 Pi / Codex 双伙伴界面生成并替换 Android 启动图标。保留包名和 `@drawable/ic_launcher` 入口；显示名称为 `Com!`。

## 成品与接入

- 原始透明 PNG：`docs/assets/com-companions-master.png`，1254 × 1254。
- 小尺寸检查图：`docs/assets/com-companions-48.png`，48 × 48。
- Android 打包资产：`android/app/src/main/res/drawable-nodpi/ic_launcher_art.png`，864 × 864，约 537 KiB。
- Android 8+ 自适应入口：`android/app/src/main/res/drawable-anydpi-v26/ic_launcher.xml`。
- 前景：`drawable/ic_launcher_foreground.xml`，四边 14 dp 内缩。
- 背景：`drawable/ic_launcher_background.xml`，暖白 `#F8F3EF`。
- 基础资源 `drawable/ic_launcher.xml` 保留兼容入口；无需修改 manifest 图标引用。

蓝色短毛绒圆脸与深蓝贝雷帽代表 Codex，珍珠流体圆脸代表 Pi。两者靠在一起，没有字母和额外徽章，以保证小尺寸识别。生成图保持透明，不把圆角、阴影底板或系统蒙版烘焙进前景。

## 生成方式与参考

使用 Codex 内置 `image_gen` 工具，未使用 CLI 或额外 API 密钥。引用用户提供的 `PlushDot-preview.png` 以及前一版本的 `home-fixed-inner.png`，仅用于角色外观。输出已复制到项目，Android 不依赖 Codex 私有生成目录。`sips` 只负责打包尺寸缩放。

完整提示词：

> Use case: logo-brand. Create one production Android launcher icon foreground asset for an AI companion app named Com!, but NO text or letters anywhere. Output square 1024x1024 PNG with genuinely transparent background. Reference image 1 is ONLY the identity reference for the blue plush companion (powder periwinkle blue short fuzzy round toy with two dark vertical pill eyes and a dark navy jaunty beret). Reference image 2 is ONLY the identity reference for the pearly fluid Pi round face (smooth porcelain pearl round soft sphere, two charcoal vertical pill eyes, no hat). Do NOT recreate the screenshot UI, captions, status badges, or sheet. Compose exactly these two expressive round faces as one distinctive compact app mark: pearly Pi slightly behind and upper-left, blue plush Codex slightly forward and lower-right, gently touching or slightly overlapping, both faces clearly legible and facing viewer. Their expressive black eyes are the main high-contrast graphic. Beautiful restrained premium 3D toy rendering, soft studio key light upper-left, refined subtle material texture, tactile blue microfleece and smooth cool pearl, small warm coral glint where they meet. No mouths needed on Pi; Codex may have tiny subtle smile. Crucial Android masking constraints: entire joined pair including beret must fit inside a centered 620x620 pixel circle (roughly x202..822,y202..822), generous TRANSPARENT space around; visual group center exactly image center. No surrounding container, no floor, no ground shadow, no backdrop, no border, no gradients outside the objects, no extra symbols, no green badges, no legs, no limbs. It should remain recognizable at 48px icon size. Clean alpha edges and polished crafted finish.

## 检查

- 原始图包含真实 alpha 通道；目视检查了两种材质、双角色眼睛和贝雷帽。
- 48 px 缩略图仍可识别两张脸和两种材质。
- 生成图未完全遵循提示词的边距，因此通过 Android 前景的 14 dp 内缩完成系统裁切适配。
- 对 alpha > 32 的可见像素计算：内缩后离中心最远 31.73 dp，位于 Android 自适应图标中央 66 dp 安全圆内（半径 33 dp）。
- XML 引用与语法已检查。最终桌面显示需随整包构建安装后检查，不以静态资产检查替代实机验收。
