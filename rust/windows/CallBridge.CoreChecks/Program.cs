// 无设备的跨语言集成检查：真正加载 Rust 动态库，验证 C# 的布局、字节单位和停止语义。
using System.Runtime.InteropServices;
using System.Text;
using CallBridge.Windows;

if (args.Length != 1) throw new ArgumentException("Pass the absolute path to the Rust core dynamic library.");
var library = NativeLibrary.Load(Path.GetFullPath(args[0]));
NativeLibrary.SetDllImportResolver(typeof(Core).Assembly, (name, _, _) => name == "callbridge_abi_probe" ? library : IntPtr.Zero);
var checks = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException(name);
    Console.WriteLine("PASS " + name); checks++;
}

Check(Marshal.SizeOf<Session>() == 16, "Session C ABI layout");
var session = new Session();
var text = Encoding.UTF8.GetBytes("Windows 中文与 emoji 🦊");
Check(Core.cb_session_begin(ref session, text, (uint)text.Length) == 0 && session.State == 1, "UTF-8 session begins");
var oldGeneration = session.Generation;
Core.cb_session_cancel(ref session);
Check(Core.cb_session_ready(ref session, oldGeneration) == -3, "cancelled synthesis cannot restart playback");

using (var player = new PlayerHandle(Core.cb_player_create([.25f, -.5f], 2, 2)))
{
    Check(!player.IsInvalid, "Rust copies valid PCM");
    var provider = new RustWaveProvider(player);
    var bytes = Enumerable.Repeat((byte)0x7f, 48).ToArray();
    Check(provider.Read(bytes, 8, 32) == 32, "stereo frames use byte count correctly");
    Check(BitConverter.ToSingle(bytes, 8) == .25f && BitConverter.ToSingle(bytes, 12) == .25f &&
          BitConverter.ToSingle(bytes, 16) == -.5f && BitConverter.ToSingle(bytes, 20) == -.5f,
          "mono speech reaches exactly the first two channels");
    Check(bytes.AsSpan(24, 16).IndexOfAnyExcept((byte)0) == -1 && bytes.Take(8).All(b => b == 0x7f) && bytes.Skip(40).All(b => b == 0x7f),
          "tail is silence and caller guards are preserved");
    Check(Core.cb_player_done(player) == 1 && provider.Read(bytes, 0, 32) == 0, "EOS only after Rust drain");
}
using (var player = new PlayerHandle(Core.cb_player_create([.5f, .5f], 2, 2)))
{
    var provider = new RustWaveProvider(player); Core.cb_player_cancel(player);
    var bytes = Enumerable.Repeat((byte)0x7f, 32).ToArray();
    Check(provider.Read(bytes, 0, 32) == 32 && bytes.All(b => b == 0), "cancellation renders silence");
    Check(Core.cb_player_done(player) == 0, "cancellation is not normal completion");
    Check(provider.Read(bytes, 32, 0) == 0, "zero-byte terminal read is safe");
    Array.Fill(bytes, (byte)0x7f);
    Check(provider.Read(bytes, 0, 31) == 0 && provider.Error != 0 && bytes.Take(31).All(b => b == 0), "partial frame fails closed");
}
using (var player = new PlayerHandle(Core.cb_player_create([float.NaN], 1, 0)))
    Check(player.IsInvalid, "non-finite PCM rejected across ABI");
using (var stream = new BoundedPcmStream())
{
    stream.SetLength(48000 * 30 * 2); stream.Position = stream.Length;
    var rejected = false;
    try { stream.Write([1, 2], 0, 2); } catch (IOException) { rejected = true; }
    Check(rejected && stream.Length == 48000 * 30 * 2, "TTS stream rejects overflow without extending storage");
}
// 验证真实页面行为：返回祖先、多个展开窗口和独立运行画面不共享媒体状态。
var navigation = new Navigation();
foreach (var id in new[] { "main", "text", "visual", "people", "detail" }) navigation.Register(id);
navigation.Register("runtime", false);
navigation.Show("main"); navigation.Show("visual", "main"); navigation.Show("people", "visual"); navigation.Show("detail", "people");
Check(!navigation.Entries["main"].Visible && !navigation.Entries["visual"].Visible && navigation.Entries["detail"].Visible, "nested visual pages fold parents independently");
Check(navigation.Back("detail") == "people" && !navigation.Entries["detail"].Visible && navigation.Entries["people"].Visible, "Back restores parent and retains detail tab");
navigation.Show("main");
Check(navigation.Entries["people"].Visible && navigation.Entries["main"].Visible, "opening a tab permits coexisting panels");
navigation.Show("text", "main"); navigation.Show("main", "text");
Check(navigation.Entries["main"].Parent == null && navigation.Entries["text"].Parent == "main", "reentering an ancestor does not create a navigation cycle");
navigation.Show("runtime", "detail"); navigation.Back("runtime"); navigation.Fold("runtime");
Check(navigation.Entries["runtime"].Visible && navigation.Entries["detail"].Visible, "returning to details keeps running canvas expanded");
navigation.Dismiss("text"); navigation.Show("text");
Check(navigation.Entries["text"].Open && navigation.Entries["text"].Visible, "closed text panel can reopen without replacing its editor");
navigation.Unregister("people");
Check(navigation.Entries["detail"].Parent == "visual" && navigation.Back("detail") == "visual", "closing a parent reconnects remaining descendants");
var visual = new VisualSelection();
Check(visual.Snapshot() == new VisualSnapshot("none", "original", null, null), "new visual selection starts without substitution");
visual.SelectBackdropOnly(); visual.SelectBackground("image", "coast.jpg");
var backdrop = visual.Snapshot();
Check(backdrop.BackgroundOnly && backdrop.Person == "none" && backdrop.CharacterPath == null, "backdrop-only has no character or camera input");
visual.SelectPerson(null);
Check(!visual.Snapshot().BackgroundOnly && backdrop.BackgroundOnly, "switching framing leaves the open preview snapshot intact");
visual.SelectPerson("character.vrm"); visual.SelectBackground("sample"); var snapshot = visual.Snapshot();
visual.EnterBackgrounds(false); visual.SelectBackground("image", "plate.png");
Check(snapshot.Person == "avatar" && snapshot.Background == "sample" && visual.Person == "none", "catalog edits cannot mutate running composition snapshot");
visual.SelectPerson(null); visual.EnterBackgrounds(true);
Check(visual.Person == "avatar", "pairing background preserves person selection");
visual.DeclinePartner(true); Check(visual.Person == "none" && visual.Background == "image", "background detail decline clears person only");
visual.SelectPerson(null); visual.DeclinePartner(false);
Check(visual.Person == "avatar" && visual.Background == "original" && visual.BackgroundPath == null, "person detail decline clears background only");
foreach (var candidate in new[] { ("custom", (string?)null), ("image", "movie.mp4"), ("unknown", "plate.png") })
{
    var rejected = false; try { visual.SelectBackground(candidate.Item1, candidate.Item2); } catch (ArgumentException) { rejected = true; }
    Check(rejected, "invalid background is rejected: " + candidate.Item1);
}
Check(PreparedCountdown.Decide(9, 10, false, true) == CountdownDecision.Pending, "countdown cannot fire early");
Check(PreparedCountdown.Decide(10, 10, true, true) == CountdownDecision.Wait, "foreground application cannot receive timed speech");
Check(PreparedCountdown.Decide(11.01, 10, false, true) == CountdownDecision.Wait, "late timer cannot send old speech");
Check(PreparedCountdown.Decide(10, 10, false, false) == CountdownDecision.Wait, "revoked countdown cannot send");
Check(PreparedCountdown.Decide(10.2, 10, false, true) == CountdownDecision.Play, "authorized timely background countdown can trigger");
Check(Core.cb_session_begin(ref session, text, (uint)text.Length) == 0 && Core.cb_session_prepared(ref session, session.Generation) == 0, "prepare speech before countdown through ABI");
var generation = session.Generation;
Check(Core.cb_session_countdown(ref session, generation) == 0 && session.State == 4, "countdown is owned by Rust session");
Check(Core.cb_session_wait_prepared(ref session, generation) == 0 && session.State == 3, "cancel countdown retains prepared speech");
Core.cb_session_countdown(ref session, generation); Core.cb_session_cancel(ref session);
Check(Core.cb_session_play_prepared(ref session, generation) == -3 && session.State == 0, "cancelled countdown generation cannot play");
Console.WriteLine($"{checks} checks passed; no audio devices or speech services opened.");
