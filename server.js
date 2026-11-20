/**
 * Al-Fath Smart Scheduler (شركة الفتح للأنظمة الذكية)
 * Node.js & Express Production Server
 * Compatible with Railway, Render, Docker, and Local Environments.
 */

const express = require('express');
const cors = require('cors');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 5560;
const DB_PATH = path.join(__dirname, 'database.json');

app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname)));

// Helper to read DB
function getDB() {
  try {
    if (!fs.existsSync(DB_PATH)) {
      return { settings: {}, technicians: [], clients: [], appointments: [] };
    }
    const data = fs.readFileSync(DB_PATH, 'utf8');
    return JSON.parse(data);
  } catch (err) {
    console.error('Error reading DB:', err);
    return { settings: {}, technicians: [], clients: [], appointments: [] };
  }
}

// Helper to save DB
function saveDB(data) {
  try {
    fs.writeFileSync(DB_PATH, JSON.stringify(data, null, 2), 'utf8');
  } catch (err) {
    console.error('Error saving DB:', err);
  }
}

// 1. Settings API
app.get('/api/settings', (req, res) => {
  const db = getDB();
  res.json(db.settings || {});
});

app.post('/api/settings', (req, res) => {
  const db = getDB();
  db.settings = { ...db.settings, ...req.body };
  saveDB(db);
  res.json(db.settings);
});

// 2. Appointments API
app.get('/api/appointments', (req, res) => {
  const db = getDB();
  res.json(db.appointments || []);
});

app.post('/api/appointments', (req, res) => {
  const db = getDB();
  const newApt = req.body;
  if (!newApt.id) {
    newApt.id = 'apt_' + Math.random().toString(36).substr(2, 9);
  }
  if (!newApt.created_at) {
    newApt.created_at = new Date().toISOString();
  }

  // Auto client linking
  if (newApt.client_name && newApt.phone) {
    let client = db.clients.find(c => c.phone === newApt.phone);
    if (!client) {
      client = {
        id: 'c_' + Math.random().toString(36).substr(2, 9),
        name: newApt.client_name,
        phone: newApt.phone,
        area: newApt.area || '',
        address: newApt.address || '',
        notes: newApt.notes || '',
        created_at: new Date().toISOString()
      };
      db.clients.push(client);
    }
    newApt.client_id = client.id;
  }

  db.appointments.push(newApt);
  saveDB(db);
  res.json(newApt);
});

app.put('/api/appointments', (req, res) => {
  const db = getDB();
  const updatedApt = req.body;
  const idx = db.appointments.findIndex(a => a.id === updatedApt.id);
  if (idx !== -1) {
    db.appointments[idx] = { ...db.appointments[idx], ...updatedApt };
    saveDB(db);
    res.json(db.appointments[idx]);
  } else {
    res.status(404).json({ error: 'الموعد غير موجود' });
  }
});

app.delete('/api/appointments', (req, res) => {
  const db = getDB();
  const targetId = req.body.id || req.query.id;
  db.appointments = db.appointments.filter(a => a.id !== targetId);
  saveDB(db);
  res.json({ success: true });
});

app.post('/api/appointments/clear', (req, res) => {
  const db = getDB();
  db.appointments = [];
  saveDB(db);
  res.json({ success: true, count: 0 });
});

app.post('/api/data/clear', (req, res) => {
  const db = getDB();
  db.appointments = [];
  db.clients = [];
  if (db.settings) db.settings.emergency_closed_date = "";
  saveDB(db);
  res.json({ success: true, message: "All data cleared" });
});

// 3. Clients API
app.get('/api/clients', (req, res) => {
  const db = getDB();
  res.json(db.clients || []);
});

app.post('/api/clients/bulk', (req, res) => {
  const db = getDB();
  const newClients = req.body.clients || [];
  let addedCount = 0;
  if (!db.clients) db.clients = [];
  newClients.forEach(c => {
    if (!c.phone) return;
    const cleanPhone = String(c.phone).trim();
    const exists = db.clients.find(x => x.phone === cleanPhone);
    if (!exists) {
      db.clients.push({
        id: c.id || ('c_' + Math.random().toString(36).substr(2, 9)),
        name: c.name || 'عميل بدون اسم',
        phone: cleanPhone,
        area: c.area || '',
        address: c.address || '',
        notes: c.notes || 'تمت المزامنة من جهات الاتصال',
        created_at: new Date().toISOString()
      });
      addedCount++;
    }
  });
  saveDB(db);
  res.json({ success: true, added_count: addedCount, total_clients: db.clients.length });
});

// 4. Emergency Close Day API
app.post('/api/emergency/close-today', (req, res) => {
  const db = getDB();
  const today = new Date().toISOString().split('T')[0];
  const affected = [];
  const template = db.settings?.whatsapp_templates?.emergency || 
    "عزيزنا العميل {client_name}، نعتذر بشدة لحدوث ظرف طارئ خارج عن إرادتنا استوجب إغلاق حجوزات اليوم. سنتواصل معكم فوراً لتحديد موعد بديل. شركة الفتح للأنظمة الذكية.";

  db.appointments.forEach(apt => {
    if (apt.date === today && apt.status !== 'cancelled') {
      apt.status = 'postponed';
      apt.priority = 'postponed';
      const msg = template
        .replace('{client_name}', apt.client_name)
        .replace('{time}', apt.time)
        .replace('{type}', apt.type);
      affected.push({
        appointment_id: apt.id,
        client_name: apt.client_name,
        phone: apt.phone,
        time: apt.time,
        suggested_message: msg,
        whatsapp_link: `https://wa.me/2${(apt.phone || '').replace(/[^0-9]/g, '')}?text=${encodeURIComponent(msg)}`
      });
    }
  });

  db.settings.emergency_closed_date = today;
  saveDB(db);
  res.json({ success: true, date: today, affected_count: affected.length, clients: affected });
});

// 5. Due Reminders API (Ready for WhatsApp Bot Integration)
app.get('/api/reminders/due', (req, res) => {
  const db = getDB();
  const now = new Date();
  const today = now.toISOString().split('T')[0];
  const due = [];

  db.appointments.forEach(apt => {
    if (apt.date === today && apt.status === 'confirmed') {
      try {
        const [h, m] = apt.time.split(':').map(Number);
        const aptDate = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, m);
        const diffMinutes = Math.round((aptDate - now) / 60000);
        const buffer = parseInt(apt.travel_buffer || 45, 10);
        const template = db.settings?.whatsapp_templates?.reminder_2h || 
          "تذكير من شركة الفتح للأنظمة الذكية: موعدكم المحدد لـ {type} اليوم في تمام الساعة {time}. يسعدنا خدمتكم!";
        const msg = template
          .replace('{client_name}', apt.client_name)
          .replace('{time}', apt.time)
          .replace('{type}', apt.type);

        if (diffMinutes > 0 && diffMinutes <= 150) {
          const departure = new Date(aptDate.getTime() - buffer * 60000);
          due.push({
            appointment_id: apt.id,
            client_name: apt.client_name,
            phone: apt.phone,
            time: apt.time,
            minutes_remaining: diffMinutes,
            travel_buffer: buffer,
            travel_departure_time: departure.toTimeString().substr(0, 5),
            message: msg,
            whatsapp_link: `https://wa.me/2${(apt.phone || '').replace(/[^0-9]/g, '')}?text=${encodeURIComponent(msg)}`
          });
        }
      } catch (e) {}
    }
  });

  res.json(due);
});

// 6. Public Booking API
app.post('/api/booking', (req, res) => {
  const db = getDB();
  const bookData = req.body;
  if (db.settings?.emergency_closed_date === bookData.date) {
    return res.status(400).json({ error: 'عذراً، هذا اليوم مغلق ولا يقبل حجوزات حالياً' });
  }

  const approvalMode = db.settings?.booking_approval_mode || 'manual';
  const initialStatus = approvalMode === 'auto' ? 'confirmed' : 'pending';

  const newBooking = {
    id: 'apt_bk_' + Math.random().toString(36).substr(2, 9),
    client_id: null,
    client_name: bookData.name,
    phone: bookData.phone,
    type: bookData.service_type || 'inspection',
    title: `طلب حجز: ${bookData.service_type} - ${bookData.name}`,
    date: bookData.date,
    time: bookData.time,
    duration: 60,
    travel_buffer: parseInt(db.settings?.default_buffer_minutes || 45, 10),
    priority: 'normal',
    status: initialStatus,
    area: bookData.area || '',
    address: bookData.address || '',
    map_link: bookData.map_link || '',
    fee: '0',
    notes: bookData.notes || '',
    technician_id: 1,
    created_at: new Date().toISOString()
  };

  db.appointments.push(newBooking);
  saveDB(db);

  res.json({
    success: true,
    status: initialStatus,
    message: initialStatus === 'confirmed' 
      ? 'تم تأكيد حجزكم بنجاح وسيتواصل معكم فني الشركة.' 
      : 'تم استلام طلبكم بنجاح وجارٍ مراجعته والتأكيد معكم عبر الواتساب.',
    booking: newBooking
  });
});

// 7. AI Command Assistant API
app.post('/api/ai/command', async (req, res) => {
  const db = getDB();
  const { prompt } = req.body;
  const p = (prompt || '').toLowerCase();
  let reply = '';
  let actionTaken = null;

  // Local Egyptian NLP fallback
  if (p.includes('جدول') || (p.includes('النهاردة') && (p.includes('لخص') || p.includes('عندي')))) {
    const today = new Date().toISOString().split('T')[0];
    const todayApts = db.appointments.filter(a => a.date === today && a.status !== 'cancelled');
    if (todayApts.length === 0) {
      reply = 'يا أستاذ سليمان، جدولك النهاردة فاضي تماماً. تحب نسكن موعد من سلة المؤجلات؟';
    } else {
      reply = `جدولك النهاردة يا أستاذ سليمان يحتوي على ${todayApts.length} موعد:\n` +
        todayApts.map(a => `• الساعة ${a.time} - ${a.client_name} (${a.type}) في ${a.area}`).join('\n');
    }
  } else if ((p.includes('رحل') || p.includes('أجل')) && (p.includes('العصر') || p.includes('بكرة'))) {
    const today = new Date().toISOString().split('T')[0];
    const tomorrow = new Date(Date.now() + 86400000).toISOString().split('T')[0];
    let count = 0;
    db.appointments.forEach(a => {
      if (a.date === today && a.time >= '14:30') {
        a.date = tomorrow;
        count++;
      }
    });
    saveDB(db);
    actionTaken = 'reschedule_batch';
    reply = `تمام يا فندم، تم ترحيل عدد ${count} مواعيد من بعد العصر اليوم إلى يوم غد بنجاح!`;
  } else if (p.includes('احجز') || p.includes('ضيف') || p.includes('سجل')) {
    let clientName = 'عميل جديد';
    const nameMatch = prompt.match(/(لأستاذ|للمهندس|للدكتور|للعميل|أستاذ|مهندس|دكتور)\s+([^\s]+(?:\s+[^\s]+)?)/);
    if (nameMatch) clientName = nameMatch[0].replace(/^ل/, '');

    let area = 'القاهرة';
    const areaMatch = prompt.match(/(التجمع|المعادي|الشيخ زايد|أكتوبر|مدينة نصر|الشروق|مصر الجديدة)/);
    if (areaMatch) area = areaMatch[0];

    let type = 'inspection';
    if (p.includes('تركيب') || p.includes('كاميرات')) type = 'installation';
    else if (p.includes('صيانة') || p.includes('عطل')) type = 'maintenance';
    else if (p.includes('خاص')) type = 'private';

    let targetDate = new Date().toISOString().split('T')[0];
    if (p.includes('بكرة') || p.includes('غدا')) {
      targetDate = new Date(Date.now() + 86400000).toISOString().split('T')[0];
    }

    let targetTime = '14:00';
    const hourMatch = prompt.match(/الساعة\s*(\d{1,2})/);
    if (hourMatch) {
      let h = parseInt(hourMatch[1], 10);
      if ((p.includes('العصر') || p.includes('المغرب') || p.includes('مساء')) && h < 12) h += 12;
      targetTime = `${h.toString().padStart(2, '0')}:00`;
    }

    const conflict = db.appointments.find(a => a.date === targetDate && a.time === targetTime && a.status !== 'cancelled');
    if (conflict) {
      reply = `تنبيه تضارب: عندك موعد بالفعل يوم ${targetDate} الساعة ${targetTime} مع (${conflict.client_name}). أوقات شاغرة مقترحة: الساعة 02:00 م أو 06:00 م.`;
    } else {
      const newApt = {
        id: 'apt_ai_' + Math.random().toString(36).substr(2, 9),
        client_name: clientName,
        phone: '01000000000',
        type,
        title: `طلب ذكي: ${type} - ${clientName}`,
        date: targetDate,
        time: targetTime,
        duration: 90,
        travel_buffer: 45,
        priority: 'urgent',
        status: 'confirmed',
        area,
        address: area,
        notes: `أمر ذكي: ${prompt}`,
        technician_id: 1,
        created_at: new Date().toISOString()
      };
      db.appointments.push(newApt);
      saveDB(db);
      actionTaken = 'appointment_created';
      reply = `عظيم جداً يا فندم! تم حجز موعد (${type}) باسم ${clientName} في ${area} يوم ${targetDate} الساعة ${targetTime} بنجاح.`;
    }
  } else {
    reply = "أهلاً بك يا فندم في المساعد الذكي لشركة الفتح! أنا جاهز لتسجيل المواعيد بصوتك أو كتابة، ترحيل المواعيد، أو فحص التضارب.";
  }

  res.json({ reply, action: actionTaken });
});

// Routing for /book
app.get('/book', (req, res) => {
  res.sendFile(path.join(__dirname, 'book.html'));
});

// Catch-all to index.html for SPA
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

app.listen(PORT, () => {
  console.log(`Al-Fath Scheduler Node.js Server running on port ${PORT}`);
});
