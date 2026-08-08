-- loopiii v1.0.0
pset_init("loopiii")

local ins, rem = table.insert, table.remove
local max, min, flr, ceil = math.max, math.min, math.floor, math.ceil
local function clamp(v, min_v, max_v) return max(min_v, min(v, max_v)) end

local N_TRK, curr_trk = 6, 1
local function midi_pitchbend(val, ch)
  if _G.midi_pitchbend then _G.midi_pitchbend(val, ch) elseif midi_pitch_bend then midi_pitch_bend(val, ch) end
end

local midi_focus, playing, act_pg = 1, false, 0
local bpm, clk_src, ppqn = 120, 1, 96
local tick_time = 60 / (bpm * ppqn)
local sys_t, taps, master_tick, grid_dirty = 0, {}, 0, true

local q_intervals = {1, 6, 12, 24, 48, 96, 192, 384}
local q_strs = {"UNQ", "/64", "/32", "/16", "/8", "/4", "/2", "/1"}
local rec_len_vals = {0, 384, 768, 1536, 3072, 6144}
local rec_len_strs = {"ANY", "1", "2", "4", "8", "16"}
local p_btns = {{3,1, 1}, {4,1, 2}, {15,1, 3}, {5,1, 4}, {16,1, 5}, {14,1, 6}}
local play_held, play_hold_time, pg_held, pg_changed = false, 0, 0, false
local cc_states = {}

local trk = {}
for i = 1, N_TRK do
  trk[i] = {
    sync_grp=0, midi_in=0, midi_out=1, swing=50, recording=false, overdub=false, armed=false, muted=false,
    speed_mode=2, loop_len=0, play_tick=0, curr_tick=0, active_notes={}, rec_active_notes={},
    raw_max_vel=0, vel_scale=1.0, quant_idx=1, quant_mod=1, rec_len_idx=1,
    rec_type={}, rec_d2={}, rec_d3={}, rec_tick={}, head={}, tail={}, next_ev={}, 
    q_head={}, q_tail={}, q_next_ev={}, active_q_offsets={}, rec_len=0,
    rec_held=false, rec_hold_time=0, rec_blink_t=0
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
  for key, count in pairs(tr.active_notes) do
    local underscore = string.find(key, "_")
    if underscore then
      local note, c = tonumber(string.sub(key, 1, underscore - 1)), tonumber(string.sub(key, underscore + 1))
      for i = 1, count do if midi_note_off then midi_note_off(note, 0, c) end end
    end
  end
  tr.active_notes = {}
  local chs = tr.midi_out == 0 and {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16} or {tr.midi_out}
  for _, c in ipairs(chs) do 
    if midi_cc then midi_cc(64, 0, c); midi_cc(123, 0, c) end 
    midi_pitchbend(8192, c)
  end
end

local function kill_all_notes() for t = 1, N_TRK do kill_notes(t) end end

local function clear_trk(t)
  local tr = trk[t]
  tr.rec_type, tr.rec_d2, tr.rec_d3, tr.rec_tick = {}, {}, {}, {}
  tr.head, tr.tail, tr.next_ev, tr.q_head, tr.q_tail, tr.q_next_ev = {}, {}, {}, {}, {}, {}
  tr.active_q_offsets, tr.rec_active_notes = {}, {}
  tr.rec_len, tr.loop_len, tr.curr_tick, tr.play_tick = 0, 0, 0, 0
  tr.raw_max_vel, tr.vel_scale = 0, 1.0
  tr.recording, tr.overdub, tr.armed = false, false, false
  kill_notes(t)
end

local m, blk_m, blk_st = nil, nil, true
local pls_v, pls_d = 2, 1
local pls_m = metro.init(function()
  pls_v = pls_v + pls_d
  if pls_v >= 10 then pls_d = -1 elseif pls_v <= 2 then pls_d = 1 end
  if act_pg == 0 then redraw() end
end, 0.1); pls_m:start()

local function clear_all_tracks()
  for t = 1, N_TRK do clear_trk(t); trk[t].rec_blink_t = sys_t end
  playing = false
  if m then m:stop() end
  collectgarbage(); redraw()
end

local function get_effective_interval(t)
  local base = q_intervals[trk[t].quant_idx]
  if trk[t].quant_idx == 1 then return 1 end
  local m_mod = trk[t].quant_mod
  return flr(base * (m_mod == 2 and (2/3) or (m_mod == 3 and 1.5 or 1)) + 0.5)
end

local function get_q_tick(t, tick_val, ty, d2)
  local tr = trk[t]
  local q_val = get_effective_interval(t)
  local delta = 0
  if q_val > 1 then
    if ty == 1 then
      delta = (flr((tick_val + (q_val/2)) / q_val) * q_val) - tick_val
      tr.active_q_offsets[d2] = delta
    elseif ty == 2 then
      delta = tr.active_q_offsets[d2] or 0
    end
  end
  local qt = flr(tick_val + delta)
  return tr.loop_len > 0 and (qt % tr.loop_len) or qt
end

local function rebuild_quant_trk(t)
  local tr = trk[t]
  tr.q_head, tr.q_tail, tr.q_next_ev, tr.active_q_offsets = {}, {}, {}, {}
  for i = 1, tr.rec_len do
    local qt = get_q_tick(t, tr.rec_tick[i], tr.rec_type[i], tr.rec_d2[i])
    if not tr.q_head[qt] then
      tr.q_head[qt], tr.q_tail[qt] = i, i
    else
      tr.q_next_ev[tr.q_tail[qt]] = i
      tr.q_tail[qt] = i
    end
    tr.q_next_ev[i] = 0
  end
end

local function insert_event(t, tick_val, ty, d2, d3)
  local tr = trk[t]
  local qt = get_q_tick(t, tick_val, ty, d2)

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
  tr.rec_type[idx], tr.rec_d2[idx], tr.rec_d3[idx], tr.rec_tick[idx] = ty, d2, d3, tick_val
  
  if not tr.head[tick_val] then
    tr.head[tick_val], tr.tail[tick_val] = idx, idx
  else
    tr.next_ev[tr.tail[tick_val]] = idx
    tr.tail[tick_val] = idx
  end
  tr.next_ev[idx] = 0
  
  if not tr.q_head[qt] then
    tr.q_head[qt], tr.q_tail[qt] = idx, idx
  else
    tr.q_next_ev[tr.q_tail[qt]] = idx
    tr.q_tail[qt] = idx
  end
  tr.q_next_ev[idx] = 0
  tr.rec_len = idx
end

local function play_ev(t, ev_t, d2, d3)
  local tr = trk[t]
  local chs = tr.midi_out == 0 and {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16} or {tr.midi_out}
  local mod_d3 = d3
  if ev_t == 1 or ev_t == 2 then mod_d3 = clamp(flr(d3 * tr.vel_scale + 0.5), ev_t == 1 and 1 or 0, 127) end
  for _, c in ipairs(chs) do
    local key = d2 .. "_" .. c
    if ev_t == 1 then 
      if midi_note_on then midi_note_on(d2, mod_d3, c) end
      tr.active_notes[key] = (tr.active_notes[key] or 0) + 1
    elseif ev_t == 2 then 
      if midi_note_off then midi_note_off(d2, mod_d3, c) end
      if tr.active_notes[key] then
        tr.active_notes[key] = tr.active_notes[key] - 1
        if tr.active_notes[key] <= 0 then tr.active_notes[key] = nil end
      end
    elseif ev_t == 3 and midi_cc then midi_cc(d2, mod_d3, c)
    elseif ev_t == 4 then midi_pitchbend((d3 * 128) + d2, c) end
  end
end

local function evaluate_tick(t, tick_val)
  if not trk[t].muted then
    local idx = trk[t].q_head[tick_val] or 0
    while idx > 0 do
      play_ev(t, trk[t].rec_type[idx], trk[t].rec_d2[idx], trk[t].rec_d3[idx])
      idx = trk[t].q_next_ev[idx]
    end
  end
end

local function loop_tick()
  if playing then
    for t = 1, N_TRK do
      local tr = trk[t]
      if tr.recording and tr.loop_len == 0 then
        tr.play_tick = tr.play_tick + 1
        tr.curr_tick = flr(tr.play_tick)
      elseif tr.loop_len > 0 then
        local last_tick = flr(tr.play_tick)
        local inc = tr.recording and 1 or (tr.speed_mode == 1 and 0.5 or (tr.speed_mode == 2 and 1 or 2))
        tr.play_tick = tr.play_tick + inc
        while tr.play_tick >= tr.loop_len do 
          tr.play_tick, last_tick = tr.play_tick - tr.loop_len, last_tick - tr.loop_len
          if tr.recording then tr.recording = false; rebuild_quant_trk(t) end
        end
        tr.curr_tick = flr(tr.play_tick)
        if tr.curr_tick ~= last_tick then
          if inc == 2 then evaluate_tick(t, (last_tick + 1) % tr.loop_len) end
          evaluate_tick(t, tr.curr_tick)
        end
      end
    end
  end
  master_tick = master_tick + 1
  m.time = tick_time * (((master_tick % (ppqn / 2)) < (ppqn / 4)) and (trk[curr_trk].swing / 50) or ((100 - trk[curr_trk].swing) / 50))
  redraw()
end

m = metro.init(loop_tick, tick_time)
blk_m = metro.init(function() blk_st = not blk_st; redraw() end, (60/bpm)/2)

local function upd_tempo()
  tick_time = 60 / (bpm * ppqn)
  blk_m.time = (60/bpm)/2
  if clk_src == 1 and playing then m:start() else m:stop() end
end

local function set_loop_length_and_close(t)
  local tr = trk[t]
  if not tr.recording then return end
  tr.recording = false
  tr.loop_len = tr.loop_len == 0 and max(1, flr(tr.play_tick)) or tr.loop_len
  tr.play_tick = (tr.play_tick % tr.loop_len) - 1
  rebuild_quant_trk(t)
end

local function close_rec_and_ovd(ignore_t)
  for i = 1, N_TRK do
    if i ~= ignore_t then
      if trk[i].recording then set_loop_length_and_close(i) end
      trk[i].overdub, trk[i].armed = false, false
    end
  end
end

local used_midi_psets, active_midi_pset = {}, 0
local pset_held, pset_hold_time = 0, 0
local pset_svd, pset_bl_n, pset_bl_t = false, nil, 0

local function save_global_pset() pset_write(100, {cur_pr = active_midi_pset}) end

local function save_midi_pset(p)
  local data = {}
  for t = 1, N_TRK do data[t] = {i = trk[t].midi_in, o = trk[t].midi_out} end
  pset_write(p, data)
  used_midi_psets[p], active_midi_pset = true, p
  save_global_pset()
end

local function load_midi_pset(p)
  local data = pset_read(p)
  if data then
    for t = 1, N_TRK do if data[t] then trk[t].midi_in, trk[t].midi_out = data[t].i or trk[t].midi_in, data[t].o or trk[t].midi_out end end
  else
    for t = 1, N_TRK do trk[t].midi_in, trk[t].midi_out = 0, 1 end
  end
  active_midi_pset = p
  save_global_pset(); redraw()
end

local sys_m = metro.init(function() 
  sys_t = sys_t + 0.1 
  if pset_held > 0 and not pset_svd and (sys_t - pset_hold_time) >= 2.0 then
    save_midi_pset(pset_held)
    pset_svd, pset_bl_n, pset_bl_t = true, pset_held, sys_t
    redraw()
  end
  if pset_bl_n and (sys_t - pset_bl_t) >= 0.75 then pset_bl_n = nil; redraw() end
  
  for t = 1, N_TRK do
    if trk[t].rec_held and (sys_t - trk[t].rec_hold_time) >= 2.0 then
      clear_trk(t)
      trk[t].rec_held, trk[t].rec_blink_t = false, sys_t
      collectgarbage(); redraw()
    end
  end
  if play_held and (sys_t - play_hold_time) >= 2.0 then play_held = false; clear_all_tracks() end
  
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
  else
    fn(target_t)
  end
end

function event_grid(x, y, z)
  if (act_pg == 2 or act_pg == 3 or act_pg == 4 or act_pg == 6) and x == 16 and y >= 3 and y <= 8 then
    if z == 1 then curr_trk = y - 2; redraw() end
    return
  end

  local is_page_btn, t_pg = false, 0
  for _, pb in ipairs(p_btns) do if x == pb[1] and y == pb[2] then is_page_btn, t_pg = true, pb[3] end end

  if is_page_btn then
    if z == 1 then
      pg_held, pg_changed = t_pg, false
      if act_pg ~= t_pg then act_pg, pg_changed = t_pg, true end
    else
      if pg_held == t_pg then
        if not pg_changed and act_pg == t_pg then act_pg = 0 end
        pg_held = 0
      end
    end
    redraw(); return
  end

  if y == 1 then
    if x >= 7 and x <= 6 + N_TRK then
      local t, tr = x - 6, trk[x - 6]
      if z == 1 then
        tr.rec_held, tr.rec_hold_time = true, sys_t
      else
        local was_held = tr.rec_held
        tr.rec_held = false
        if was_held and (sys_t - tr.rec_hold_time) < 2.0 then
          if tr.loop_len == 0 or (tr.recording and tr.loop_len > 0) then
            if not tr.recording then
              local tgt_arm = not tr.armed
              close_rec_and_ovd(0)
              local master_idx = 0
              if tgt_arm and tr.loop_len == 0 and tr.sync_grp > 0 then
                for i = 1, N_TRK do if i ~= t and trk[i].sync_grp == tr.sync_grp and trk[i].loop_len > 0 then master_idx = i; break end end
              end
              if master_idx > 0 then
                tr.loop_len, tr.play_tick, tr.curr_tick = trk[master_idx].loop_len, trk[master_idx].play_tick, trk[master_idx].curr_tick
                tr.rec_len_idx, tr.recording, tr.overdub, tr.armed, curr_trk = trk[master_idx].rec_len_idx, false, true, false, t
              else
                tr.armed, curr_trk = tgt_arm, t
              end
            else set_loop_length_and_close(t) end
          else
            local tgt_ovd = not tr.overdub
            close_rec_and_ovd(0)
            tr.overdub = tgt_ovd
            if tgt_ovd then curr_trk = t end
          end
        end
      end
      redraw(); return
    end

    if x == 1 then
      if z == 1 then play_held, play_hold_time = true, sys_t
      else
        local was_held = play_held
        play_held = false
        if was_held and (sys_t - play_hold_time) < 2.0 then
          playing = not playing
          if playing then 
            if clk_src == 1 then m:start() end
            for t = 1, N_TRK do if trk[t].loop_len > 0 then evaluate_tick(t, trk[t].curr_tick) end end
          else m:stop(); kill_all_notes() end
        end
        redraw()
      end
      return
    end

    if x == 2 and z == 1 then
      for t = 1, N_TRK do trk[t].play_tick, trk[t].curr_tick = 0, 0 end
      master_tick = 0; kill_all_notes()
      if playing then for t = 1, N_TRK do if trk[t].loop_len > 0 then evaluate_tick(t, 0) end end end
      redraw(); return
    end
  end

  if act_pg == 1 and z == 1 then
    if y == 2 then
      if x == 1 then
        if #taps > 0 and (sys_t - taps[#taps]) > 2.0 then taps = {} end
        if #taps > 0 and (sys_t - taps[#taps]) < 0.1 then return end
        ins(taps, sys_t)
        if #taps > 1 then local d = (sys_t - taps[1]) / (#taps - 1); if d > 0 then bpm = flr(clamp(60/d, 20, 300)); upd_tempo() end end
        if #taps > 4 then rem(taps, 1) end
      elseif x == 3 or x == 4 then clk_src = (x==3) and 1 or 2; upd_tempo() end
    elseif x == 13 and clk_src == 1 then
      local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 10) or (y==8 and -10)
      if d then bpm = clamp(bpm+d, 20, 300); upd_tempo() end
    end
    redraw(); return 

  elseif act_pg == 2 and z == 1 and x == 13 then
    local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 5) or (y==8 and -5)
    if d then 
      local nv = clamp(trk[curr_trk].swing + d, 25, 75)
      apply_trk(curr_trk, function(t) trk[t].swing = nv end)
      upd_tempo(); redraw()
    end
    return

  elseif act_pg == 3 then
    if z == 1 and y == 2 and (x == 1 or x == 2) then 
      midi_focus = x; if pg_held == 3 then pg_changed = true end
    elseif y == 2 and x >= 4 and x <= 11 then
      local p = x - 3
      if z == 1 then pset_held, pset_hold_time, pset_svd = p, sys_t, false
      elseif pset_held == p then
        pset_held = 0
        if not pset_svd and (sys_t - pset_hold_time) < 2.0 then load_midi_pset(p) end
      end
      redraw(); return
    elseif z == 1 and x == 13 then
      local d = (y==4 and 1) or (y==5 and -1) or (y==7 and 5) or (y==8 and -5)
      if d then 
        local nv_in, nv_out = clamp(trk[curr_trk].midi_in + d, -1, 16), clamp(trk[curr_trk].midi_out + d, -1, 16)
        apply_trk(curr_trk, function(t) 
          if midi_focus == 1 then trk[t].midi_in = nv_in else trk[t].midi_out = nv_out end
        end)
      end
    end
    redraw(); return

  elseif act_pg == 4 and z == 1 then
    if y == 2 then
      if x >= 1 and x <= 8 then
        apply_trk(curr_trk, function(t) trk[t].quant_idx = x; kill_notes(t); rebuild_quant_trk(t) end)
      elseif x >= 14 and x <= 16 then
        if trk[curr_trk].quant_idx > 1 then
          apply_trk(curr_trk, function(t) trk[t].quant_mod = x - 13; kill_notes(t); rebuild_quant_trk(t) end)
        end
      end
    end
    redraw(); return

  elseif act_pg == 5 and z == 1 then
    if y >= 3 and y <= 8 then
      local target_t = y - 2
      if x >= 1 and x <= 10 then
        local base_vel = trk[target_t].raw_max_vel
        if base_vel > 0 then apply_trk(target_t, function(t) trk[t].vel_scale = (x * 12.7) / base_vel end) end
      elseif x >= 12 and x <= 14 then
        apply_trk(target_t, function(t) trk[t].speed_mode = x - 11; kill_notes(t) end)
      elseif x == 16 then
        local tgt_mute = not trk[target_t].muted
        apply_trk(target_t, function(t) 
          trk[t].muted = (pg_held == 5) and tgt_mute or not trk[t].muted
          if trk[t].muted then kill_notes(t) end
        end)
      end
    end
    redraw(); return

  elseif act_pg == 6 and z == 1 then
    if y == 2 and x >= 1 and x <= 6 then
      apply_trk(curr_trk, function(t) 
        trk[t].rec_len_idx = x 
        if trk[t].sync_grp > 0 then for i = 1, N_TRK do if trk[i].sync_grp == trk[t].sync_grp then trk[i].rec_len_idx = x end end end
      end)
    elseif x == 14 and y >= 3 and y <= 8 then
      local target_t = y - 2
      local new_sg = (trk[target_t].sync_grp + 1) % 4
      trk[target_t].sync_grp = new_sg
      if new_sg > 0 then
        for i = 1, N_TRK do if i ~= target_t and trk[i].sync_grp == new_sg then trk[target_t].rec_len_idx = trk[i].rec_len_idx; break end end
      end
    end
    redraw(); return
  end
end

function event_midi(d1, d2, d3)
  local status, ch_in = d1 - (d1 % 16), (d1 % 16) + 1
  local ev_t = (status == 144) and (d3 == 0 and 2 or 1) or (status == 128 and 2) or (status == 176 and 3) or (status == 224 and 4) or nil

  if ev_t == 3 and ((d2 >= 103 and d2 <= 109) or (d2 >= 110 and d2 <= 119)) then
    local z = d3 > 63 and 1 or 0
    if cc_states[d2] ~= z then
      cc_states[d2] = z
      if d2 == 103 and z == 1 then
        trk[curr_trk].muted = not trk[curr_trk].muted
        if trk[curr_trk].muted then kill_notes(curr_trk) end; redraw()
      elseif d2 >= 104 and d2 <= 109 and z == 1 then
        local target_t = d2 - 103
        trk[target_t].muted = not trk[target_t].muted
        if trk[target_t].muted then kill_notes(target_t) end; redraw()
      elseif d2 == 110 then event_grid(6 + curr_trk, 1, z)
      elseif d2 >= 111 and d2 <= 116 then event_grid(6 + (d2 - 110), 1, z)
      elseif d2 == 117 and z == 1 then curr_trk = (curr_trk % N_TRK) + 1; redraw()
      elseif d2 == 118 then event_grid(1, 1, z)
      elseif d2 == 119 then event_grid(2, 1, z) end
    end
    return
  end

  if ev_t then
    for t = 1, N_TRK do
      local tr = trk[t]
      if tr.midi_in == 0 or tr.midi_in == ch_in then
        if tr.armed and (ev_t == 1 or ev_t == 3 or ev_t == 4) then
          close_rec_and_ovd(t)
          tr.armed, tr.recording, playing = false, true, true
          tr.rec_type, tr.rec_d2, tr.rec_d3, tr.rec_tick = {}, {}, {}, {}
          tr.head, tr.tail, tr.next_ev, tr.q_head, tr.q_tail, tr.q_next_ev = {}, {}, {}, {}, {}, {}
          tr.active_q_offsets, tr.rec_active_notes = {}, {}
          tr.rec_len, tr.raw_max_vel, tr.vel_scale = 0, 0, 1.0
          
          local master_idx = 0
          if tr.sync_grp > 0 then for i = 1, N_TRK do if i ~= t and trk[i].sync_grp == tr.sync_grp and trk[i].loop_len > 0 then master_idx = i; break end end end
          
          if master_idx > 0 then
            tr.loop_len, tr.play_tick, tr.curr_tick = trk[master_idx].loop_len, trk[master_idx].play_tick, trk[master_idx].curr_tick
            tr.rec_len_idx, tr.recording, tr.overdub = trk[master_idx].rec_len_idx, false, true
          else
            tr.curr_tick, tr.play_tick, tr.loop_len = 0, 0, rec_len_vals[tr.rec_len_idx]
          end
          if clk_src == 1 then m:start() end
        end

        if tr.recording or tr.overdub or (ev_t == 2 and tr.rec_active_notes[d2]) then
          insert_event(t, tr.curr_tick, ev_t, d2, d3)
          if ev_t == 1 then
            tr.rec_active_notes[d2] = true
            if d3 > tr.raw_max_vel then tr.raw_max_vel = d3 end
          elseif ev_t == 2 then tr.rec_active_notes[d2] = nil end
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
        if tr.armed or (tr.recording and tr.loop_len == 0) then base_br = pls_v
        elseif tr.loop_len > 0 then
          local pos = flr((tr.curr_tick / tr.loop_len) * 16) + 1
          if tr.overdub then base_br = (i == pos) and 15 or pls_v
          else base_br = tr.muted and ((i == pos) and 4 or 1) or ((i == pos) and 15 or (tr.recording and pls_v or 2)) end
        end
        grid_led(i, 2 + t, base_br)
      end
    end
  elseif act_pg == 1 then
    grid_led(1, 2, blk_st and 15 or 4); grid_led(3, 2, clk_src == 1 and 15 or 4); grid_led(4, 2, clk_src == 2 and 15 or 4) 
    if clk_src == 1 then draw_inc_b(13) end
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
    for i = 1, 8 do grid_led(i, 2, t_q.quant_idx == i and 15 or 4) end
    for i = 1, 3 do grid_led(13 + i, 2, (t_q.quant_idx > 1 and t_q.quant_mod == i) and 15 or ((t_q.quant_idx > 1) and 4 or 1)) end
    draw_text(q_strs[t_q.quant_idx] .. (t_q.quant_idx > 1 and (t_q.quant_mod == 2 and "T" or (t_q.quant_mod == 3 and "." or "")) or ""), 1, 4)
  elseif act_pg == 5 then
    for t = 1, N_TRK do
      local tr, lit = trk[t], clamp(ceil((trk[t].raw_max_vel * trk[t].vel_scale) / 12.7), 0, 10)
      for i = 1, 10 do grid_led(i, 2 + t, i <= lit and 15 or 1) end
      grid_led(12, 2 + t, tr.speed_mode == 1 and 15 or 4); grid_led(13, 2 + t, tr.speed_mode == 2 and 15 or 4)
      grid_led(14, 2 + t, tr.speed_mode == 3 and 15 or 4); grid_led(16, 2 + t, tr.muted and 2 or 15)
    end
  elseif act_pg == 6 then
    for i = 1, 6 do grid_led(i, 2, trk[curr_trk].rec_len_idx == i and 15 or 4) end
    draw_text(rec_len_strs[trk[curr_trk].rec_len_idx], 1, 4)
    for t = 1, N_TRK do
      local sg = trk[t].sync_grp
      grid_led(14, 2 + t, (sg == 1) and 10 or ((sg == 2) and (blk_st and 12 or 2) or ((sg == 3) and pls_v or 1)))
    end
  end
  grid_refresh()
end

local function init_midi_psets()
  for i = 1, 8 do used_midi_psets[i] = pset_read(i) and true or false end
  local gst = pset_read(100)
  if gst and gst.cur_pr and gst.cur_pr >= 1 and gst.cur_pr <= 8 then 
    active_midi_pset = gst.cur_pr; load_midi_pset(gst.cur_pr)
  else active_midi_pset = 0 end
end

init_midi_psets(); sys_m:start(); blk_m:start(); upd_tempo()
local rndr_m = metro.init(function() if grid_dirty then hw_redraw(); grid_dirty = false end end, 1/30); rndr_m:start()