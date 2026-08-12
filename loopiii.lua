-- loopiii v1.0.0
pset_init("loopiii")

local ins, rem = table.insert, table.remove
local max, min, flr, ceil = math.max, math.min, math.floor, math.ceil
local function clamp(v, min_v, max_v) return max(min_v, min(v, max_v)) end

local N_TRK, curr_trk = 6, 1
local function midi_pitchbend(val, ch)
  if _G.midi_pitchbend then _G.midi_pitchbend(val, ch) elseif midi_pitch_bend then midi_pitch_bend(val, ch) end
end

local function wipe_table(tbl)
  for k in pairs(tbl) do tbl[k] = nil end
end

local midi_focus, playing, act_pg = 1, false, 0
local bpm, clk_src, ppqn, send_midi_clk = 120, 1, 96, true
local tick_time = 60 / (bpm * ppqn)
local sys_t, taps, master_tick, grid_dirty = 0, {}, 0, true

local q_intervals = {1, 6, 12, 24, 48, 96, 192, 384}
local q_strs = {"UNQ", "/64", "/32", "/16", "/8", "/4", "/2", "/1"}
local rec_len_vals = {0, 6144, 3072, 1536, 768, 384}
local rec_len_strs = {"ANY", "16", "8", "4", "2", "1"}
local p_btns = {{3,1, 1}, {4,1, 2}, {15,1, 3}, {5,1, 4}, {16,1, 5}, {14,1, 6}}
local play_held, play_hold_time, pg_held, pg_changed = false, 0, 0, false
local cc_states = {}

local trk = {}
for i = 1, N_TRK do
  trk[i] = {
    s_grp=0, midi_in=0, midi_out=1, swing=50, recording=false, overdub=false, armed=false, muted=false,
    spd_m=2, loop_len=0, b_len=0, b_idx=1, st_fac=1.0, 
    play_tick=0, curr_tick=0, l_cyc=0, act_n={}, r_an={},
    raw_max_vel=0, vel_scale=1.0, q_idx=1, q_mod=1, rl_idx=1,
    rec_type={}, rec_d2={}, rec_d3={}, rec_tick={}, r_mc={},
    q_head={}, q_tail={}, q_next_ev={}, q_offs={}, rec_len=0,
    rec_held=false, rec_hold_time=0, rec_blink_t=0,
    paused=false, btn1_held=false, btn2_held=false, one_shot=false
  }
end

local font = {
  [37]="101001010100101", [46]="000000000000010", [47]="001001010100100", [48]="011101101101110", [49]="010110010010111", 
  [50]="110001111100111", [51]="110001111001111", [52]="101101111001001", [53]="111100111001110", [54]="011100111101111", 
  [55]="111001010010010", [56]="011101111101110", [57]="111101111001110", [65]="011101111101101", [69]="111100110100111", 
  [70]="111100111100100", [76]="100100100100111", [78]="110101101101101", [79]="011101101101110", [81]="011101101110011", 
  [84]="111010010010010", [85]="101101101101011", [88]="101101010101101", [89]="101101111001110"
}

local bpm_strs, swing_strs, ch_strs = {}, {}, {[-1]="OFF", [0]="ALL"}
for i=20,300 do bpm_strs[i]=tostring(i) end
for i=25,75 do swing_strs[i]=tostring(i).."%" end
for i=1,16 do ch_strs[i]=tostring(i) end

local m, blk_m, blk_st = nil, nil, true
local pls_v, pls_d = 2, 1

function redraw() grid_dirty = true end

local function draw_text(str, st_x, st_y)
  if not str then return end
  for c = 1, #str do
    local p = font[string.byte(str, c)]
    if p then for i=1,15 do if string.byte(p, i)==49 then grid_led(st_x+(c-1)*4+((i-1)%3), st_y+flr((i-1)/3), 5) end end end
  end
end

local function draw_inc_b(c) grid_led(c,4,12); grid_led(c,5,6); grid_led(c,7,12); grid_led(c,8,6) end

local function kill_notes(t)
  local tr = trk[t]
  for key, count in pairs(tr.act_n) do
    local c = flr(key / 1000)
    local note = key % 1000
    for i = 1, count do if midi_note_off then midi_note_off(note, 0, c) end end
  end
  wipe_table(tr.act_n)
end

local function kill_all_notes() for t = 1, N_TRK do kill_notes(t) end end

local function clear_seq(t)
  local tr = trk[t]
  wipe_table(tr.rec_type); wipe_table(tr.rec_d2); wipe_table(tr.rec_d3); wipe_table(tr.rec_tick)
  wipe_table(tr.q_head); wipe_table(tr.q_tail); wipe_table(tr.q_next_ev); wipe_table(tr.q_offs)
  wipe_table(tr.r_an); wipe_table(tr.r_mc)
  tr.rec_len, tr.l_cyc = 0, 0
end

local function clear_trk(t)
  local tr = trk[t]
  kill_notes(t); clear_seq(t)
  tr.loop_len, tr.curr_tick, tr.play_tick = 0, 0, 0
  tr.b_len, tr.b_idx, tr.st_fac = 0, 1, 1.0
  tr.raw_max_vel, tr.vel_scale = 0, 1.0
  tr.recording, tr.overdub, tr.armed, tr.paused = false, false, false, false
end

local function clear_all_tracks()
  for t = 1, N_TRK do clear_trk(t); trk[t].rec_blink_t = sys_t end
  playing = false
  if m then m:stop() end
  collectgarbage(); redraw()
end

local function get_effective_interval(t)
  local base = q_intervals[trk[t].q_idx]
  if trk[t].q_idx == 1 then return 1 end
  return flr(base * (trk[t].q_mod == 2 and (2/3) or (trk[t].q_mod == 3 and 1.5 or 1)) + 0.5)
end

local function get_q_tick(t, tick_val, ty, d2)
  local tr = trk[t]
  local q_val = get_effective_interval(t)
  local delta = 0
  if q_val > 1 then
    if ty == 1 then
      delta = (flr((tick_val + (q_val/2)) / q_val) * q_val) - tick_val
      tr.q_offs[d2] = delta
    elseif ty == 2 then
      delta = tr.q_offs[d2] or 0
    end
  end
  local qt = flr(tick_val + delta)
  return (tr.loop_len > 0 and (qt % tr.loop_len) or qt), delta
end

local function reb_q(t)
  local tr = trk[t]
  wipe_table(tr.q_head); wipe_table(tr.q_tail); wipe_table(tr.q_next_ev); wipe_table(tr.q_offs)
  for i = 1, tr.rec_len do
    local stretched_tick = tr.rec_tick[i] * tr.st_fac
    local qt = get_q_tick(t, stretched_tick, tr.rec_type[i], tr.rec_d2[i])
    if not tr.q_head[qt] then
      tr.q_head[qt], tr.q_tail[qt] = i, i
    else
      tr.q_next_ev[tr.q_tail[qt]] = i
      tr.q_tail[qt] = i
    end
    tr.q_next_ev[i] = 0
  end
end

local function set_len_cl(t)
  local tr = trk[t]
  if not tr.recording then return end
  tr.recording = false
  tr.loop_len = tr.loop_len == 0 and max(1, flr(tr.play_tick)) or tr.loop_len
  tr.b_len, tr.b_idx, tr.st_fac = tr.loop_len, tr.rl_idx, 1.0
  tr.play_tick = (tr.play_tick % tr.loop_len) - 1
  wipe_table(tr.r_mc); reb_q(t)
end

local function cl_rec_ovd(ignore_t)
  for i = 1, N_TRK do
    if i ~= ignore_t then
      if trk[i].recording then set_len_cl(i) end
      if trk[i].overdub then wipe_table(trk[i].r_mc) end
      trk[i].overdub, trk[i].armed = false, false
    end
  end
end

local function toggle_rec(t)
  local tr = trk[t]
  if tr.loop_len == 0 or (tr.recording and tr.loop_len > 0) then
    if not tr.recording then
      local tgt_arm = not tr.armed
      cl_rec_ovd(0)
      local m_idx = 0
      if tgt_arm and tr.loop_len == 0 and tr.s_grp > 0 then
        for i = 1, N_TRK do if i ~= t and trk[i].s_grp == tr.s_grp and trk[i].loop_len > 0 then m_idx = i; break end end
      end
      if m_idx > 0 then
        local mtr = trk[m_idx]
        tr.loop_len, tr.play_tick, tr.curr_tick = mtr.loop_len, mtr.play_tick, mtr.curr_tick
        tr.b_len, tr.b_idx, tr.st_fac = mtr.b_len, mtr.b_idx, mtr.st_fac
        tr.rl_idx, tr.recording, tr.overdub, tr.armed, curr_trk = mtr.rl_idx, false, true, false, t
        tr.paused = false
      else
        tr.armed, curr_trk = tgt_arm, t
        if tgt_arm then tr.paused = false end
      end
    else set_len_cl(t) end
  else
    local tgt_ovd = not tr.overdub
    cl_rec_ovd(0)
    tr.overdub = tgt_ovd
    if not tgt_ovd then wipe_table(tr.r_mc) end
    if tgt_ovd then curr_trk = t; tr.paused = false end
  end
end

local function insert_event(t, tick_val, ty, d2, d3)
  local tr = trk[t]
  local qt, delta = get_q_tick(t, tick_val, ty, d2)

  if ty == 3 or ty == 4 then
    local q_idx = tr.q_head[qt]
    while q_idx and q_idx > 0 do
      if tr.rec_type[q_idx] == ty and (ty == 4 or tr.rec_d2[q_idx] == d2) then
        tr.rec_d3[q_idx] = d3
        if ty == 4 then tr.rec_d2[q_idx] = d2 end
        return
      end
      q_idx = tr.q_next_ev[q_idx]
    end
  end

  local idx = tr.rec_len + 1
  tr.rec_type[idx], tr.rec_d2[idx], tr.rec_d3[idx], tr.rec_tick[idx] = ty, d2, d3, tick_val / tr.st_fac
  
  local mute_cycle = -1
  if tr.loop_len == 0 then
    mute_cycle = (delta >= 0) and tr.l_cyc or -1
  else
    if delta >= 0 then mute_cycle = (tick_val + delta >= tr.loop_len) and (tr.l_cyc + 1) or tr.l_cyc end
  end
  tr.r_mc[idx] = mute_cycle
  
  if not tr.q_head[qt] then tr.q_head[qt], tr.q_tail[qt] = idx, idx
  else tr.q_next_ev[tr.q_tail[qt]] = idx; tr.q_tail[qt] = idx end
  tr.q_next_ev[idx], tr.rec_len = 0, idx
end

local function play_ev(t, ev_t, d2, d3)
  local tr = trk[t]
  local chs = tr.midi_out == 0 and {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16} or {tr.midi_out}
  local mod_d3 = d3
  if ev_t == 1 or ev_t == 2 then mod_d3 = clamp(flr(d3 * tr.vel_scale + 0.5), ev_t == 1 and 1 or 0, 127) end
  for _, c in ipairs(chs) do
    local key = c * 1000 + d2
    if ev_t == 1 then 
      if midi_note_on then midi_note_on(d2, mod_d3, c) end
      tr.act_n[key] = (tr.act_n[key] or 0) + 1
    elseif ev_t == 2 then 
      if midi_note_off then midi_note_off(d2, mod_d3, c) end
      if tr.act_n[key] then
        tr.act_n[key] = tr.act_n[key] - 1
        if tr.act_n[key] <= 0 then tr.act_n[key] = nil end
      end
    elseif ev_t == 3 and midi_cc then midi_cc(d2, mod_d3, c)
    elseif ev_t == 4 then midi_pitchbend((d3 * 128) + d2, c) end
  end
end

local function eval_tk(t, tick_val)
  if not trk[t].muted then
    local idx = trk[t].q_head[tick_val] or 0
    while idx > 0 do
      if not ((trk[t].overdub or trk[t].recording) and trk[t].r_mc[idx] == trk[t].l_cyc) then
        play_ev(t, trk[t].rec_type[idx], trk[t].rec_d2[idx], trk[t].rec_d3[idx])
      end
      idx = trk[t].q_next_ev[idx]
    end
  end
end

local function start_rec_from_arm(t, was_playing)
  local tr = trk[t]
  cl_rec_ovd(t)
  tr.armed, tr.recording, playing, tr.paused = false, true, true, false
  clear_seq(t)
  tr.raw_max_vel, tr.vel_scale = 0, 1.0
  
  local m_idx = 0
  if tr.s_grp > 0 then for i = 1, N_TRK do if i ~= t and trk[i].s_grp == tr.s_grp and trk[i].loop_len > 0 then m_idx = i; break end end end
  
  if m_idx > 0 then
    local mtr = trk[m_idx]
    tr.loop_len, tr.play_tick, tr.curr_tick = mtr.loop_len, mtr.play_tick, mtr.curr_tick
    tr.b_len, tr.b_idx, tr.st_fac = mtr.b_len, mtr.b_idx, mtr.st_fac
    tr.rl_idx, tr.recording, tr.overdub = mtr.rl_idx, false, true
  else
    tr.curr_tick, tr.play_tick, tr.loop_len = 0, 0, rec_len_vals[tr.rl_idx]
    tr.b_len, tr.b_idx, tr.st_fac = 0, tr.rl_idx, 1.0
  end
  if clk_src == 1 and not was_playing then 
    for p = 1, N_TRK do trk[p].paused = false end
    m:start()
    if send_midi_clk then midi_tx(250) end 
  end
end

local function t_play_toggle(t)
  local tr = trk[t]
  tr.paused = not tr.paused
  if tr.paused then 
    kill_notes(t)
    if tr.recording then set_len_cl(t) end
    tr.overdub, tr.armed = false, false
  elseif playing and tr.loop_len > 0 then
    eval_tk(t, tr.curr_tick)
  end
end

local function t_reset(t)
  local tr = trk[t]
  tr.play_tick, tr.curr_tick, tr.l_cyc = 0, 0, 0
  wipe_table(tr.r_mc); kill_notes(t)
  if playing and not tr.paused and tr.loop_len > 0 then eval_tk(t, 0) end
end

local function toggle_mute(t)
  trk[t].muted = not trk[t].muted
  if trk[t].muted then kill_notes(t) end
end

local function g_play_toggle()
  playing = not playing
  if playing then 
    for t = 1, N_TRK do trk[t].paused = false end
    if clk_src == 1 then m:start(); if send_midi_clk then midi_tx(250) end end
    for t = 1, N_TRK do if trk[t].loop_len > 0 and not trk[t].paused then eval_tk(t, trk[t].curr_tick) end end
  else 
    m:stop(); kill_all_notes()
    if clk_src == 1 and send_midi_clk then midi_tx(252) end
  end
end

local function g_reset()
  for t = 1, N_TRK do trk[t].play_tick, trk[t].curr_tick, trk[t].l_cyc = 0, 0, 0; wipe_table(trk[t].r_mc) end
  master_tick = 0; kill_all_notes()
  if clk_src == 1 and playing and send_midi_clk then midi_tx(252); midi_tx(250) end
  if playing then for t = 1, N_TRK do if trk[t].loop_len > 0 and not trk[t].paused then eval_tk(t, 0) end end end
end

local function loop_tick()
  if playing then
    for t = 1, N_TRK do
      local tr = trk[t]
      if not tr.paused then
        if tr.recording and tr.loop_len == 0 then
          tr.play_tick = tr.play_tick + 1
          tr.curr_tick = flr(tr.play_tick)
        elseif tr.loop_len > 0 then
          local last_tick = flr(tr.play_tick)
          local inc = tr.recording and 1 or (tr.spd_m == 1 and 0.5 or (tr.spd_m == 2 and 1 or 2))
          tr.play_tick = tr.play_tick + inc
          
          if tr.play_tick >= tr.loop_len and tr.one_shot and not tr.recording then
            for tk = last_tick + 1, tr.loop_len - 1 do eval_tk(t, tk) end
            tr.paused = true
            tr.play_tick, tr.curr_tick, tr.l_cyc = 0, 0, 0
            wipe_table(tr.r_mc); kill_notes(t)
          else
            while tr.play_tick >= tr.loop_len do 
              tr.play_tick = tr.play_tick - tr.loop_len
              last_tick = last_tick - tr.loop_len
              tr.l_cyc = tr.l_cyc + 1
              if tr.recording then tr.recording = false; reb_q(t) end
            end
            tr.curr_tick = flr(tr.play_tick)
            if tr.curr_tick ~= last_tick then
              if inc == 2 then eval_tk(t, (last_tick + 1) % tr.loop_len) end
              eval_tk(t, tr.curr_tick)
            end
          end
        end
      end
    end
  end
  master_tick = master_tick + 1
  m.time = tick_time * (((master_tick % (ppqn / 2)) < (ppqn / 4)) and (trk[curr_trk].swing / 50) or ((100 - trk[curr_trk].swing) / 50))
  redraw()
end

pls_m = metro.init(function()
  pls_v = pls_v + pls_d
  if pls_v >= 10 then pls_d = -1 elseif pls_v <= 2 then pls_d = 1 end
  if act_pg == 0 then redraw() end
end, 0.1); pls_m:start()

m = metro.init(loop_tick, tick_time)
blk_m = metro.init(function() blk_st = not blk_st; redraw() end, (60/bpm)/2)
local midi_clk_m = metro.init(function() if clk_src == 1 and send_midi_clk then midi_tx(248) end end, (60 / bpm) / 24)

local function upd_tempo()
  tick_time = 60 / (bpm * ppqn)
  blk_m.time, midi_clk_m.time = (60/bpm)/2, (60/bpm)/24
  if clk_src == 1 and playing then m:start() else m:stop() end
end

local used_midi_psets, active_midi_pset = {}, 0
local pset_held, pset_hold_time = 0, 0
local pset_svd, pset_bl_n, pset_bl_t = false, nil, 0

local function save_global_pset() pset_write(100, {cur_pr = active_midi_pset}) end

local function save_midi_pset(p)
  local data = {}
  for t = 1, N_TRK do data[t] = {i = trk[t].midi_in, o = trk[t].midi_out} end
  pset_write(p, data)
  used_midi_psets[p], active_midi_pset = true, p; save_global_pset()
end

local function load_midi_pset(p)
  local data = pset_read(p)
  if data then
    for t = 1, N_TRK do if data[t] then trk[t].midi_in, trk[t].midi_out = data[t].i or trk[t].midi_in, data[t].o or trk[t].midi_out end end
  else
    for t = 1, N_TRK do trk[t].midi_in, trk[t].midi_out = 0, 1 end
  end
  active_midi_pset = p; save_global_pset(); redraw()
end

local sys_m = metro.init(function() 
  sys_t = sys_t + 0.1 
  if pset_held > 0 and not pset_svd and (sys_t - pset_hold_time) >= 2.0 then
    save_midi_pset(pset_held); pset_svd, pset_bl_n, pset_bl_t = true, pset_held, sys_t; redraw()
  end
  if pset_bl_n and (sys_t - pset_bl_t) >= 0.75 then pset_bl_n = nil; redraw() end
  
  for t = 1, N_TRK do
    if trk[t].rec_held and (sys_t - trk[t].rec_hold_time) >= 2.0 then
      clear_trk(t); trk[t].rec_held, trk[t].rec_blink_t = false, sys_t; collectgarbage(); redraw()
    end
  end
  if play_held and (sys_t - play_hold_time) >= 2.0 then 
    play_held = false; clear_all_tracks() 
    if clk_src == 1 and send_midi_clk then midi_tx(252) end
  end
  
  local blinked = false
  for t = 1, N_TRK do
    if trk[t].rec_blink_t > 0 and (sys_t - trk[t].rec_blink_t) >= 0.75 then trk[t].rec_blink_t = 0; blinked = true end
  end
  if blinked then redraw() end
end, 0.1)

local function apply_trk(target_t, fn)
  if pg_held == act_pg and act_pg > 1 then
    for i = 1, N_TRK do fn(i) end
    pg_changed = true
  else fn(target_t) end
end

local function upd_st(t, new_idx)
  local tr = trk[t]
  tr.rl_idx = new_idx
  if tr.b_len > 0 then
    kill_notes(t)
    tr.st_fac = (new_idx == 1 or new_idx == tr.b_idx) and 1.0 or (rec_len_vals[new_idx] / tr.b_len)
    local old_len = tr.loop_len
    tr.loop_len = flr(tr.b_len * tr.st_fac)
    if old_len > 0 then
      tr.play_tick = (tr.play_tick / old_len) * tr.loop_len
      tr.curr_tick = flr(tr.play_tick)
    end
    reb_q(t); collectgarbage()
  end
end

function event_grid(x, y, z)
  if act_pg == 0 and y >= 3 and y <= 8 then
    local t = y - 2
    if x == 1 then
      trk[t].btn1_held = (z == 1)
      if z == 1 then t_play_toggle(t); redraw() end
      return
    elseif x == 2 then
      trk[t].btn2_held = (z == 1)
      if z == 1 then t_reset(t); redraw() end
      return
    elseif x == 16 then
      if z == 1 then trk[t].one_shot = not trk[t].one_shot; redraw() end
      return
    end
  end

  if (act_pg == 2 or act_pg == 3 or act_pg == 4 or act_pg == 6) and x == 16 and y >= 3 and y <= 8 then
    if z == 1 then curr_trk = y - 2; redraw() end; return
  end

  local is_page_btn, t_pg = false, 0
  for _, pb in ipairs(p_btns) do if x == pb[1] and y == pb[2] then is_page_btn, t_pg = true, pb[3] end end

  if is_page_btn then
    if z == 1 then pg_held, pg_changed = t_pg, false; if act_pg ~= t_pg then act_pg, pg_changed = t_pg, true end
    else if pg_held == t_pg then if not pg_changed and act_pg == t_pg then act_pg = 0 end; pg_held = 0 end end
    redraw(); return
  end

  if y == 1 then
    if x >= 7 and x <= 6 + N_TRK then
      local t = x - 6
      if z == 1 then trk[t].rec_held, trk[t].rec_hold_time = true, sys_t
      else
        local was_held = trk[t].rec_held
        trk[t].rec_held = false
        if was_held and (sys_t - trk[t].rec_hold_time) < 2.0 then toggle_rec(t) end
      end
      redraw(); return
    end
    if x == 1 then
      if z == 1 then play_held, play_hold_time = true, sys_t
      else
        local was_held = play_held
        play_held = false
        if was_held and (sys_t - play_hold_time) < 2.0 then g_play_toggle() end
        redraw()
      end
      return
    end
    if x == 2 and z == 1 then g_reset(); redraw(); return end
  end

  if act_pg == 1 and z == 1 then
    if y == 2 then
      if x == 1 then
        if #taps > 0 and (sys_t - taps[#taps]) > 2.0 then taps = {} end
        if #taps > 0 and (sys_t - taps[#taps]) < 0.1 then return end
        ins(taps, sys_t)
        if #taps > 1 then local d = (sys_t - taps[1]) / (#taps - 1); if d > 0 then bpm = flr(clamp(60/d, 20, 300)); upd_tempo() end end
        if #taps > 4 then rem(taps, 1) end
      elseif x == 3 or x == 4 then clk_src = (x==3) and 1 or 2; upd_tempo() 
      elseif x == 16 and clk_src == 1 then send_midi_clk = not send_midi_clk; redraw(); return
      end
    elseif x == 13 and clk_src == 1 then
      local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 10) or (y==8 and -10)
      if d then bpm = clamp(bpm+d, 20, 300); upd_tempo() end
    end
    redraw(); return 

  elseif act_pg == 2 and z == 1 and x == 13 then
    local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 5) or (y==8 and -5)
    if d then apply_trk(curr_trk, function(t) trk[t].swing = clamp(trk[curr_trk].swing + d, 25, 75) end); upd_tempo(); redraw() end
    return

  elseif act_pg == 3 then
    if z == 1 and y == 2 and (x == 1 or x == 2) then midi_focus = x; if pg_held == 3 then pg_changed = true end
    elseif y == 2 and x >= 4 and x <= 11 then
      local p = x - 3
      if z == 1 then pset_held, pset_hold_time, pset_svd = p, sys_t, false
      elseif pset_held == p then
        pset_held = 0; if not pset_svd and (sys_t - pset_hold_time) < 2.0 then load_midi_pset(p) end
      end
      redraw(); return
    elseif z == 1 and x == 13 then
      local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 5) or (y==8 and -5)
      if d then 
        local nv_in, nv_out = clamp(trk[curr_trk].midi_in + d, -1, 16), clamp(trk[curr_trk].midi_out + d, -1, 16)
        apply_trk(curr_trk, function(t) if midi_focus == 1 then trk[t].midi_in = nv_in else trk[t].midi_out = nv_out end end)
      end
    end
    redraw(); return

  elseif act_pg == 4 and z == 1 then
    if y == 2 then
      if x >= 1 and x <= 8 then apply_trk(curr_trk, function(t) trk[t].q_idx = x; kill_notes(t); reb_q(t) end)
      elseif x >= 14 and x <= 16 and trk[curr_trk].q_idx > 1 then apply_trk(curr_trk, function(t) trk[t].q_mod = x - 13; kill_notes(t); reb_q(t) end)
      end
    end
    redraw(); return

  elseif act_pg == 5 and z == 1 then
    if y >= 3 and y <= 8 then
      local target_t = y - 2
      if x >= 1 and x <= 10 then
        local base_vel = trk[target_t].raw_max_vel
        if base_vel > 0 then apply_trk(target_t, function(t) trk[t].vel_scale = (x * 12.7) / base_vel end) end
      elseif x >= 12 and x <= 14 then apply_trk(target_t, function(t) trk[t].spd_m = x - 11; kill_notes(t) end)
      elseif x == 16 then 
        if pg_held == 5 then
          local all_muted = true
          for i = 1, N_TRK do if not trk[i].muted then all_muted = false; break end end
          local target_mute = not all_muted
          for i = 1, N_TRK do 
            trk[i].muted = target_mute
            if target_mute then kill_notes(i) end
          end
        else
          toggle_mute(target_t)
        end
      end
    end
    redraw(); return

  elseif act_pg == 6 and z == 1 then
    if y == 2 and x >= 1 and x <= 6 then
      apply_trk(curr_trk, function(t) 
        upd_st(t, x)
        if trk[t].s_grp > 0 then for i = 1, N_TRK do if i ~= t and trk[i].s_grp == trk[t].s_grp then upd_st(i, x) end end end
      end)
    elseif x == 14 and y >= 3 and y <= 8 then
      local target_t = y - 2
      local new_sg = (trk[target_t].s_grp + 1) % 4
      trk[target_t].s_grp = new_sg
      if new_sg > 0 then for i = 1, N_TRK do if i ~= target_t and trk[i].s_grp == new_sg then upd_st(target_t, trk[i].rl_idx); break end end end
    end
    redraw(); return
  end
end

function event_midi(d1, d2, d3)
  local status, ch_in = d1 - (d1 % 16), (d1 % 16) + 1
  local ev_t = (status == 144) and (d3 == 0 and 2 or 1) or (status == 128 and 2) or (status == 176 and 3) or (status == 224 and 4) or nil

  if ev_t == 3 and (d2 >= 102 and d2 <= 112) then
    local z = d3 > 63 and 1 or 0
    if cc_states[d2] ~= z then
      cc_states[d2] = z
      if z == 1 then
        if d2 == 102 then g_play_toggle(); redraw()
        elseif d2 == 103 then g_reset(); redraw()
        elseif d2 == 104 then curr_trk = ((curr_trk - 2) % N_TRK) + 1; redraw()
        elseif d2 == 105 then curr_trk = (curr_trk % N_TRK) + 1; redraw()
        elseif d2 == 106 then toggle_rec(curr_trk); redraw()
        elseif d2 == 107 then t_play_toggle(curr_trk); redraw()
        elseif d2 == 108 then t_reset(curr_trk); redraw()
        elseif d2 == 109 then toggle_mute(curr_trk); redraw()
        elseif d2 >= 110 and d2 <= 112 then trk[curr_trk].spd_m = d2 - 109; kill_notes(curr_trk); redraw()
        end
      end
    end
    return
  end

  if ev_t then
    for t = 1, N_TRK do
      local tr = trk[t]
      if tr.midi_in == 0 or tr.midi_in == ch_in then
        if tr.armed and (ev_t == 1 or ev_t == 3 or ev_t == 4) then start_rec_from_arm(t, playing) end

        if tr.overdub and not playing and (ev_t == 1 or ev_t == 3 or ev_t == 4) then
          playing = true
          tr.paused = false
          if clk_src == 1 then for p = 1, N_TRK do trk[p].paused = false end; m:start(); if send_midi_clk then midi_tx(250) end end
          for i = 1, N_TRK do if trk[i].loop_len > 0 and not trk[i].paused then eval_tk(i, trk[i].curr_tick) end end
        end

        if tr.recording or tr.overdub or (ev_t == 2 and tr.r_an[d2]) then
          tr.paused = false
          insert_event(t, tr.curr_tick, ev_t, d2, d3)
          if ev_t == 1 then
            tr.r_an[d2] = true
            if d3 > tr.raw_max_vel then tr.raw_max_vel = d3 end
          elseif ev_t == 2 then tr.r_an[d2] = nil end
        end
      end
    end
  end
end

local function hw_redraw()
  grid_led_all(0)
  grid_led(1, 1, playing and 15 or 4); grid_led(2, 1, 4)
  
  for t = 1, N_TRK do
    local tr, is_curr = trk[t], (t == curr_trk)
    local rec_led = is_curr and 6 or 2 
    if tr.loop_len > 0 then rec_led = is_curr and 15 or 10 end
    if tr.rec_blink_t > 0 then rec_led = blk_st and 15 or 0 elseif tr.armed or tr.recording or tr.overdub then rec_led = pls_v end
    grid_led(6 + t, 1, rec_led)
  end
  
  for _, pb in ipairs(p_btns) do
    local br = (act_pg == pb[3]) and (pb[3] == 1 and (blk_st and 15 or 6) or 15) or (pb[3] == 1 and (blk_st and 8 or 2) or 4)
    grid_led(pb[1], pb[2], br)
  end

  if act_pg == 2 or act_pg == 3 or act_pg == 4 or act_pg == 6 then
    for t = 1, N_TRK do grid_led(16, 2 + t, (pg_held == act_pg or curr_trk == t) and 15 or 4) end
  end
  
  if act_pg == 0 then
    for t = 1, N_TRK do
      local tr = trk[t]
      for i = 1, 16 do
        local base_br = 1
        if tr.btn1_held and i == 1 then base_br = 15
        elseif tr.btn2_held and i == 2 then base_br = 15
        else
          if tr.armed or (tr.recording and tr.loop_len == 0) then base_br = pls_v
          elseif tr.loop_len > 0 then
            local pos = flr((tr.curr_tick / tr.loop_len) * 16) + 1
            if tr.overdub then base_br = (i == pos) and 15 or pls_v
            else base_br = tr.muted and ((i == pos) and 10 or 1) or ((i == pos) and 15 or (tr.recording and pls_v or 8)) end
          end
          if i == 16 and tr.one_shot then base_br = 15 end
        end
        grid_led(i, 2 + t, base_br)
      end
    end
  elseif act_pg == 1 then
    grid_led(1, 2, blk_st and 15 or 4); grid_led(3, 2, clk_src == 1 and 15 or 4); grid_led(4, 2, clk_src == 2 and 15 or 4) 
    if clk_src == 1 then draw_inc_b(13); grid_led(16, 2, send_midi_clk and 15 or 1) end
    draw_text((clk_src == 2) and "EXT" or bpm_strs[flr(bpm + 0.5)], 1, 4)
  elseif act_pg == 2 then 
    draw_inc_b(13); draw_text(swing_strs[trk[curr_trk].swing], 1, 4)
  elseif act_pg == 3 then
    grid_led(1, 2, midi_focus == 1 and 15 or 4); grid_led(2, 2, midi_focus == 2 and 15 or 4); draw_inc_b(13)
    draw_text(ch_strs[(midi_focus == 1) and trk[curr_trk].midi_in or trk[curr_trk].midi_out], 1, 4)
    for i = 1, 8 do
      local br = 2
      if pset_bl_n == i then br = blk_st and 15 or 0 elseif i == active_midi_pset then br = 15 elseif used_midi_psets[i] then br = 10 end
      if pset_held == i and not pset_svd then br = blk_st and 15 or 0 end
      grid_led(3 + i, 2, br)
    end
  elseif act_pg == 4 then
    local t_q = trk[curr_trk]
    for i = 1, 8 do grid_led(i, 2, t_q.q_idx == i and 15 or 4) end
    for i = 1, 3 do grid_led(13 + i, 2, (t_q.q_idx > 1 and t_q.q_mod == i) and 15 or ((t_q.q_idx > 1) and 4 or 1)) end
    draw_text(q_strs[t_q.q_idx] .. (t_q.q_idx > 1 and (t_q.q_mod == 2 and "T" or (t_q.q_mod == 3 and "." or "")) or ""), 1, 4)
  elseif act_pg == 5 then
    for t = 1, N_TRK do
      local tr, lit = trk[t], clamp(ceil((trk[t].raw_max_vel * trk[t].vel_scale) / 12.7), 0, 10)
      for i = 1, 10 do grid_led(i, 2 + t, i <= lit and 15 or 1) end
      grid_led(12, 2 + t, tr.spd_m == 1 and 15 or 4); grid_led(13, 2 + t, tr.spd_m == 2 and 15 or 4)
      grid_led(14, 2 + t, tr.spd_m == 3 and 15 or 4); grid_led(16, 2 + t, tr.muted and 0 or 15)
    end
  elseif act_pg == 6 then
    for i = 1, 6 do grid_led(i, 2, trk[curr_trk].rl_idx == i and 15 or 4) end
    draw_text(rec_len_strs[trk[curr_trk].rl_idx], 1, 4)
    for t = 1, N_TRK do
      local sg = trk[t].s_grp
      grid_led(14, 2 + t, (sg == 1) and 10 or ((sg == 2) and (blk_st and 12 or 2) or ((sg == 3) and pls_v or 1)))
    end
  end
  grid_refresh()
end

local function init_midi_psets()
  for i = 1, 8 do used_midi_psets[i] = pset_read(i) and true or false end
  local gst = pset_read(100)
  if gst and gst.cur_pr and gst.cur_pr >= 1 and gst.cur_pr <= 8 then load_midi_pset(gst.cur_pr)
  else active_midi_pset = 0 end
end

init_midi_psets(); sys_m:start(); blk_m:start(); midi_clk_m:start(); upd_tempo()
local rndr_m = metro.init(function() if grid_dirty then hw_redraw(); grid_dirty = false end end, 1/30); rndr_m:start()