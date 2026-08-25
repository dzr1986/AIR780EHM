package com.panshi.mqtt;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken;
import org.eclipse.paho.client.mqttv3.MqttCallback;
import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;

import javax.swing.BorderFactory;
import javax.swing.DefaultListModel;
import javax.swing.JButton;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JList;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JProgressBar;
import javax.swing.JScrollPane;
import javax.swing.JTextArea;
import javax.swing.JTextField;
import javax.swing.SwingUtilities;
import javax.swing.UIManager;
import javax.swing.WindowConstants;
import java.awt.BorderLayout;
import java.awt.Color;
import java.awt.Dimension;
import java.awt.FlowLayout;
import java.awt.Font;
import java.awt.GridBagConstraints;
import java.awt.GridBagLayout;
import java.awt.Insets;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 磐石回放上传闭环（Java）：下发 2013 → 1013 queued → uploading 进度 → reply=0 完成。
 */
public class MqttClosedLoopApp extends JFrame implements MqttCallback {
    private static final DateTimeFormatter TS = DateTimeFormatter.ofPattern("HH:mm:ss.SSS");
    private static final DateTimeFormatter WALL = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static final DateTimeFormatter SEG_FMT = DateTimeFormatter.ofPattern("yyyyMMddHHmmss");
    /** 录像文件名格式：ch0_YYYYMMDDHHMMSS_YYYYMMDDHHMMSS.ts 或 .mp4 */
    private static final Pattern TF_SEG_RE = Pattern.compile("ch0_(\\d{14})_(\\d{14})\\.(ts|mp4)$", Pattern.CASE_INSENSITIVE);
    /** 单次 2013 上传最长 600 秒（与 Cat.1 resolveUploadWindow 一致） */
    private static final int MAX_UPLOAD_SEC = 600;

    private static final Gson GSON = new GsonBuilder().disableHtmlEscaping().create();

    private final JTextField brokerField = new JTextField(16);
    private final JTextField portField = new JTextField(5);
    private final JTextField userField = new JTextField(10);
    private final JTextField passField = new JTextField(12);
    private final JTextField imeiField = new JTextField(16);
    private final JTextField clientIdField = new JTextField(18);
    private final JLabel connLbl = new JLabel("未连接");
    private final JLabel signalLbl = new JLabel("等待 1003 信号…");
    private final JTextField beginField = new JTextField(18);
    private final JTextField endField = new JTextField(18);
    private final JLabel stageLbl = new JLabel("未开始");
    private final JProgressBar progress = new JProgressBar(0, 100);
    private final JTextArea logArea = new JTextArea();
    /** 用户选择的录像段列表 */
    private final List<RecSegment> recSegments = new ArrayList<>();
    private final DefaultListModel<String> recListModel = new DefaultListModel<>();
    private final JList<String> recList = new JList<>(recListModel);
    private final JLabel recLbl = new JLabel("未输入录像文件");
    /** 录像文件名输入框 */
    private final JTextField recFileField = new JTextField();

    private final ExecutorService pool = Executors.newCachedThreadPool();
    private MqttClient client;
    private volatile boolean connected;

    public MqttClosedLoopApp(Path cfgDir) {
        super("磐石 Cat.1 回放闭环  ·  Java  2013↔1013");
        loadConfig(cfgDir);
        buildUi();
        LocalDateTime now = LocalDateTime.now();
        beginField.setText(now.minusMinutes(5).format(WALL));
        endField.setText(now.format(WALL));
    }

    private void loadConfig(Path cfgDir) {
        Path profiles = cfgDir.resolve("profiles.json");
        Path config = cfgDir.resolve("config.json");
        JsonObject obj = null;
        try {
            if (Files.isRegularFile(profiles)) {
                JsonObject root = GSON.fromJson(Files.readString(profiles, StandardCharsets.UTF_8), JsonObject.class);
                String active = root.has("active") ? root.get("active").getAsString() : "";
                JsonArray arr = root.getAsJsonArray("profiles");
                if (arr != null) {
                    for (JsonElement el : arr) {
                        JsonObject p = el.getAsJsonObject();
                        if (active.equals(str(p, "name")) || obj == null) {
                            obj = p;
                        }
                    }
                }
            }
            if (obj == null && Files.isRegularFile(config)) {
                obj = GSON.fromJson(Files.readString(config, StandardCharsets.UTF_8), JsonObject.class);
            }
        } catch (Exception e) {
            obj = new JsonObject();
        }
        if (obj == null) {
            obj = new JsonObject();
        }
        brokerField.setText(str(obj, "broker", "112.86.146.218"));
        portField.setText(String.valueOf(obj.has("port") ? obj.get("port").getAsInt() : 2123));
        userField.setText(str(obj, "username", "fptop1"));
        passField.setText(str(obj, "password", ""));
        imeiField.setText(str(obj, "device_imei", ""));
        clientIdField.setText(str(obj, "client_id", "platform-java-001"));
    }

    private void buildUi() {
        setDefaultCloseOperation(WindowConstants.EXIT_ON_CLOSE);
        setLayout(new BorderLayout(8, 8));
        ((JPanel) getContentPane()).setBorder(BorderFactory.createEmptyBorder(8, 10, 8, 10));

        JPanel top = new JPanel(new GridBagLayout());
        GridBagConstraints c = new GridBagConstraints();
        c.insets = new Insets(2, 4, 2, 4);
        c.anchor = GridBagConstraints.WEST;
        int col = 0;
        c.gridy = 0;
        c.gridx = col++;
        top.add(new JLabel("Broker"), c);
        c.gridx = col++;
        top.add(brokerField, c);
        c.gridx = col++;
        top.add(new JLabel("端口"), c);
        c.gridx = col++;
        top.add(portField, c);
        c.gridx = col++;
        top.add(new JLabel("用户"), c);
        c.gridx = col++;
        top.add(userField, c);
        c.gridx = col++;
        top.add(new JLabel("密码"), c);
        c.gridx = col++;
        top.add(passField, c);

        col = 0;
        c.gridy = 1;
        c.gridx = col++;
        top.add(new JLabel("IMEI"), c);
        c.gridx = col++;
        top.add(imeiField, c);
        c.gridx = col++;
        top.add(new JLabel("ClientId"), c);
        c.gridx = col++;
        top.add(clientIdField, c);
        JButton connBtn = new JButton("连接");
        JButton discBtn = new JButton("断开");
        connBtn.addActionListener(e -> pool.execute(this::connectBroker));
        discBtn.addActionListener(e -> pool.execute(this::disconnectBroker));
        c.gridx = col++;
        top.add(connBtn, c);
        c.gridx = col++;
        top.add(discBtn, c);
        c.gridx = col++;
        connLbl.setForeground(new Color(0x888888));
        top.add(connLbl, c);
        add(top, BorderLayout.NORTH);

        JPanel mid = new JPanel(new BorderLayout(6, 6));
        signalLbl.setOpaque(true);
        signalLbl.setBackground(new Color(0xffeac4));
        signalLbl.setBorder(BorderFactory.createEmptyBorder(6, 8, 6, 8));
        mid.add(signalLbl, BorderLayout.NORTH);

        JPanel play = new JPanel(new BorderLayout(6, 6));
        play.setBorder(BorderFactory.createTitledBorder("回放闭环  输入录像文件名 → 2013 → 进度 → 完成"));

        // --- 录像文件名输入区 ---
        JPanel fileBar = new JPanel(new FlowLayout(FlowLayout.LEFT));
        fileBar.add(new JLabel("录像文件名"));
        recFileField.setColumns(40);
        recFileField.setToolTipText("ch0_YYYYMMDDHHMMSS_YYYYMMDDHHMMSS.ts 或 .mp4，多个用逗号或分号分隔");
        JButton addBtn = new JButton("添加");
        addBtn.addActionListener(e -> addRecFiles());
        JButton clearBtn = new JButton("清空");
        clearBtn.addActionListener(e -> {
            recSegments.clear();
            recListModel.clear();
            recLbl.setText("未输入录像文件");
        });
        fileBar.add(recFileField);
        fileBar.add(addBtn);
        fileBar.add(clearBtn);
        fileBar.add(recLbl);
        play.add(fileBar, BorderLayout.NORTH);

        // --- 时间栏 + 发送按钮 ---
        JPanel bar = new JPanel(new FlowLayout(FlowLayout.LEFT));
        bar.add(new JLabel("开始"));
        bar.add(beginField);
        bar.add(new JLabel("结束"));
        bar.add(endField);
        JButton last5 = new JButton("最近5分钟");
        last5.addActionListener(e -> {
            LocalDateTime now = LocalDateTime.now();
            beginField.setText(now.minusMinutes(5).format(WALL));
            endField.setText(now.format(WALL));
        });
        JButton send = new JButton("请求上传 2013");
        send.addActionListener(e -> pool.execute(this::send2013Loop));
        bar.add(last5);
        bar.add(send);
        JPanel centerPanel = new JPanel(new BorderLayout(4, 4));
        centerPanel.add(bar, BorderLayout.NORTH);

        JPanel prog = new JPanel(new BorderLayout(8, 0));
        stageLbl.setFont(stageLbl.getFont().deriveFont(Font.BOLD, 14f));
        progress.setStringPainted(true);
        progress.setPreferredSize(new Dimension(480, 22));
        prog.add(stageLbl, BorderLayout.WEST);
        prog.add(progress, BorderLayout.CENTER);
        centerPanel.add(prog, BorderLayout.CENTER);

        // --- 录像段列表 ---
        recList.setSelectionMode(javax.swing.ListSelectionModel.SINGLE_SELECTION);
        recList.addListSelectionListener(e -> {
            if (!e.getValueIsAdjusting() && recList.getSelectedIndex() >= 0) {
                int idx = recList.getSelectedIndex();
                if (idx < recSegments.size()) {
                    RecSegment seg = recSegments.get(idx);
                    beginField.setText(seg.begin.format(WALL));
                    endField.setText(seg.end.format(WALL));
                }
            }
        });
        JScrollPane recScroll = new JScrollPane(recList);
        recScroll.setPreferredSize(new Dimension(900, 80));
        centerPanel.add(recScroll, BorderLayout.SOUTH);

        play.add(centerPanel, BorderLayout.CENTER);

        logArea.setEditable(false);
        logArea.setFont(new Font("Consolas", Font.PLAIN, 13));
        JScrollPane sp = new JScrollPane(logArea);
        sp.setPreferredSize(new Dimension(900, 240));
        play.add(sp, BorderLayout.SOUTH);
        mid.add(play, BorderLayout.CENTER);
        add(mid, BorderLayout.CENTER);

        setPreferredSize(new Dimension(1080, 640));
        pack();
        setLocationRelativeTo(null);
        addWindowListener(new java.awt.event.WindowAdapter() {
            @Override
            public void windowClosing(java.awt.event.WindowEvent e) {
                disconnectBroker();
                pool.shutdownNow();
            }
        });
    }

    private void connectBroker() {
        disconnectBroker();
        try {
            String host = brokerField.getText().trim();
            int port = Integer.parseInt(portField.getText().trim());
            String cid = clientIdField.getText().trim();
            if (cid.isEmpty()) {
                cid = "platform-java-" + UUID.randomUUID().toString().substring(0, 6);
            }
            String uri = "tcp://" + host + ":" + port;
            final String fcid = cid;
            MqttClient c = new MqttClient(uri, cid, new MemoryPersistence());
            c.setCallback(this);
            MqttConnectOptions opt = new MqttConnectOptions();
            opt.setAutomaticReconnect(true);
            opt.setCleanSession(true);
            opt.setKeepAliveInterval(60);
            opt.setUserName(userField.getText().trim());
            opt.setPassword(passField.getText().toCharArray());
            c.connect(opt);
            String imei = imeiField.getText().trim();
            c.subscribe("/panshi/app/" + imei + "/event", 1);
            c.subscribe("/panshi/app/" + imei + "/status", 1);
            c.subscribe("/panshi/app/" + imei + "/property", 1);
            client = c;
            connected = true;
            ui(() -> {
                connLbl.setText("Connected  " + uri + "  " + fcid);
                connLbl.setForeground(new Color(0x1a7f37));
            });
            log("已连接 " + uri + "  订阅 /panshi/app/" + imei + "/#");
        } catch (Exception e) {
            connected = false;
            ui(() -> {
                connLbl.setText("连接失败");
                connLbl.setForeground(Color.RED);
            });
            log("连接失败: " + e.getMessage());
        }
    }

    private void disconnectBroker() {
        connected = false;
        MqttClient c = client;
        client = null;
        if (c != null) {
            try {
                c.disconnect();
                c.close();
            } catch (Exception ignored) {
            }
        }
        ui(() -> {
            connLbl.setText("未连接");
            connLbl.setForeground(new Color(0x888888));
        });
    }

    // ---- 录像文件名输入解析 ----

    private void addRecFiles() {
        String text = recFileField.getText().trim();
        if (text.isEmpty()) {
            ui(() -> JOptionPane.showMessageDialog(this, "请输入录像文件名"));
            return;
        }
        // 按逗号、分号、换行分隔多个文件名
        String[] names = text.split("[,;\\n\\r]+");
        int added = 0;
        for (String raw : names) {
            String name = raw.trim();
            if (name.isEmpty()) continue;
            Matcher m = TF_SEG_RE.matcher(name);
            if (!m.find()) {
                log("跳过（文件名不匹配 ch0_YYYYMMDDHHMMSS_YYYYMMDDHHMMSS.ts）: " + name);
                continue;
            }
            try {
                LocalDateTime begin = LocalDateTime.parse(m.group(1), SEG_FMT);
                LocalDateTime end = LocalDateTime.parse(m.group(2), SEG_FMT);
                recSegments.add(new RecSegment(name, begin, end, 0));
                added++;
            } catch (Exception e) {
                log("解析失败: " + name + " - " + e.getMessage());
            }
        }
        if (recSegments.isEmpty()) {
            recLbl.setText("未找到有效录像段");
            return;
        }
        recSegments.sort((a, b) -> a.begin.compareTo(b.begin));
        recListModel.clear();
        for (RecSegment seg : recSegments) {
            long dur = java.time.Duration.between(seg.begin, seg.end).getSeconds();
            recListModel.addElement(String.format("%s  %s ~ %s  (%d秒)",
                    seg.name, seg.begin.format(WALL), seg.end.format(WALL), dur));
        }
        // 自动填充第一个段的时间
        RecSegment first = recSegments.get(0);
        beginField.setText(first.begin.format(WALL));
        endField.setText(first.end.format(WALL));
        RecSegment last = recSegments.get(recSegments.size() - 1);
        long totalDur = java.time.Duration.between(first.begin, last.end).getSeconds();
        recLbl.setText(String.format("已加载 %d 段, 总时长 %d 分 %d 秒", recSegments.size(), totalDur / 60, totalDur % 60));
        log(String.format("已加载 %d 段录像: %s ~ %s", recSegments.size(),
                first.begin.format(WALL), last.end.format(WALL)));
        recFileField.setText("");
    }

    // ---- 时间窗按 600 秒拆分 ----

    private List<long[]> splitWindow(long beginTs, long endTs) {
        List<long[]> windows = new ArrayList<>();
        long cur = beginTs;
        while (cur < endTs) {
            long nxt = Math.min(endTs, cur + MAX_UPLOAD_SEC);
            windows.add(new long[]{cur, nxt});
            cur = nxt;
        }
        return windows;
    }

    // ---- 发送 2013（支持多段拆分） ----

    private void send2013Loop() {
        if (!connected || client == null) {
            ui(() -> JOptionPane.showMessageDialog(this, "请先连接 Broker"));
            return;
        }
        long beginTs;
        long endTs;
        try {
            beginTs = toUnix(beginField.getText().trim());
            endTs = toUnix(endField.getText().trim());
            if (endTs <= beginTs) {
                throw new IllegalArgumentException("结束时间必须晚于开始时间");
            }
        } catch (Exception e) {
            ui(() -> JOptionPane.showMessageDialog(this, e.getMessage()));
            return;
        }
        // 按 600 秒拆分
        List<long[]> windows = splitWindow(beginTs, endTs);
        String imei = imeiField.getText().trim();
        String topic = "/panshi/device/" + imei + "/";
        if (windows.size() > 1) {
            log(String.format("时间窗 %d 秒，拆成 %d 条 2013（单段 ≤%d 秒）",
                    endTs - beginTs, windows.size(), MAX_UPLOAD_SEC));
        }
        for (int i = 0; i < windows.size(); i++) {
            long[] w = windows.get(i);
            String mid = "play-" + (System.currentTimeMillis() / 1000) + "-" + UUID.randomUUID().toString().substring(0, 4);
            String beginTime = LocalDateTime.ofInstant(
                    java.time.Instant.ofEpochSecond(w[0]), ZoneId.systemDefault()).format(WALL);
            String endTime = LocalDateTime.ofInstant(
                    java.time.Instant.ofEpochSecond(w[1]), ZoneId.systemDefault()).format(WALL);
            JsonObject body = new JsonObject();
            body.addProperty("dataType", "2013");
            body.addProperty("messageId", mid);
            body.addProperty("action", "upload_video");
            body.addProperty("needUpload", 1);
            body.addProperty("reason", "cloud");
            body.addProperty("videoType", 2);
            body.addProperty("beginTs", w[0]);
            body.addProperty("endTs", w[1]);
            body.addProperty("beginTime", beginTime);
            body.addProperty("endTime", endTime);
            try {
                client.publish(topic, body.toString().getBytes(StandardCharsets.UTF_8), 1, false);
                if (i == 0) {
                    setStage("queued", 0, mid);
                }
                log(String.format(">> 2013 [%d/%d] %s  %s", i + 1, windows.size(), mid, body));
            } catch (Exception e) {
                log("发送失败: " + e.getMessage());
                return;
            }
            // 多段之间间隔 500ms
            if (i < windows.size() - 1) {
                try { Thread.sleep(500); } catch (InterruptedException ignored) { break; }
            }
        }
        log("等待闭环：queued → uploading% → reply=0（最长 3600s）");
    }

    @Override
    public void connectionLost(Throwable cause) {
        connected = false;
        ui(() -> {
            connLbl.setText("连接丢失");
            connLbl.setForeground(Color.RED);
        });
        log("连接丢失: " + (cause != null ? cause.getMessage() : ""));
    }

    @Override
    public void messageArrived(String topic, MqttMessage message) {
        String payload = new String(message.getPayload(), StandardCharsets.UTF_8);
        JsonObject data;
        try {
            data = GSON.fromJson(payload, JsonObject.class);
        } catch (Exception e) {
            log("<< 非 JSON  " + topic + "  " + payload);
            return;
        }
        String dt = str(data, "dataType");
        log("<< " + dt + "  " + topic + "  " + payload);
        if ("1003".equals(dt) || "1005".equals(dt)) {
            ui(() -> signalLbl.setText(String.format(
                    "%s  CSQ=%s RSRP=%s RSSI=%s RSRQ=%s SNR=%s  电量=%s%%  %s",
                    dt, str(data, "csq"), str(data, "rsrp"), str(data, "rssi"),
                    str(data, "rsrq"), str(data, "snr"), str(data, "remainPower"),
                    str(data, "workMode"))));
        }
        if ("1013".equals(dt)) {
            on1013(data);
        }
    }

    private void on1013(JsonObject data) {
        String stage = str(data, "stage");
        int reply = data.has("reply") && !data.get("reply").isJsonNull() ? data.get("reply").getAsInt() : -1;
        int pct = data.has("percent") && !data.get("percent").isJsonNull() ? data.get("percent").getAsInt() : -1;
        if (reply == 0) {
            boolean ok = !data.has("ret") || data.get("ret").isJsonNull() || data.get("ret").getAsInt() == 0;
            stage = stage.isEmpty() ? (ok ? "uploaded" : "fail") : stage;
            pct = ok ? 100 : Math.max(pct, 0);
            log(ok
                    ? "闭环完成  file=" + str(data, "fileName") + "  httpPath=" + str(data, "httpPath")
                    : "闭环失败  ret=" + str(data, "ret") + "  " + str(data, "message"));
        } else if (stage.isEmpty()) {
            stage = "queued";
        }
        if (pct < 0) {
            pct = "uploaded".equals(stage) ? 100 : progress.getValue();
        }
        setStage(stage, pct, str(data, "fileName") + " " + str(data, "message"));
    }

    @Override
    public void deliveryComplete(IMqttDeliveryToken token) {
    }

    private void setStage(String stage, int pct, String extra) {
        int p = Math.max(0, Math.min(100, pct));
        ui(() -> {
            progress.setValue(p);
            stageLbl.setText(stage + "  " + p + "%  " + (extra == null ? "" : extra));
        });
    }

    private void log(String msg) {
        String line = LocalDateTime.now().format(TS) + "  " + msg + "\n";
        ui(() -> {
            logArea.append(line);
            logArea.setCaretPosition(logArea.getDocument().getLength());
        });
    }

    private void ui(Runnable r) {
        SwingUtilities.invokeLater(r);
    }

    private static long toUnix(String wall) {
        LocalDateTime t = LocalDateTime.parse(wall, WALL);
        return t.atZone(java.time.ZoneId.systemDefault()).toEpochSecond();
    }

    private static String str(JsonObject o, String k) {
        return str(o, k, "");
    }

    private static String str(JsonObject o, String k, String dft) {
        if (o == null || !o.has(k) || o.get(k).isJsonNull()) {
            return dft;
        }
        JsonElement e = o.get(k);
        return e.isJsonPrimitive() ? e.getAsString() : dft;
    }

    /** 录像段：文件名 + 起止时间 + 大小 */
    private static class RecSegment {
        final String name;
        final LocalDateTime begin;
        final LocalDateTime end;
        final long size;

        RecSegment(String name, LocalDateTime begin, LocalDateTime end, long size) {
            this.name = name;
            this.begin = begin;
            this.end = end;
            this.size = size;
        }
    }

    public static void main(String[] args) throws Exception {
        UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName());
        Path cfgDir = Path.of(System.getProperty("mqtt.cfgdir", "../mqtt")).toAbsolutePath().normalize();
        if (!Files.isRegularFile(cfgDir.resolve("config.json"))) {
            Path alt = Path.of("").toAbsolutePath().resolve("tools/gui/mqtt");
            if (Files.isRegularFile(alt.resolve("config.json"))) {
                cfgDir = alt;
            }
        }
        Path finalCfg = cfgDir;
        SwingUtilities.invokeLater(() -> {
            MqttClosedLoopApp app = new MqttClosedLoopApp(finalCfg);
            app.setVisible(true);
        });
    }
}
