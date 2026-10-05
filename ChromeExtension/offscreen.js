const audioContexts = new Map();

chrome.runtime.onMessage.addListener(async (message, sender, sendResponse) => {
  if (message.type === 'START_CAPTURE') {
    const streamId = message.streamId;
    const tabId = message.tabId;
    
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          mandatory: {
            chromeMediaSource: 'tab',
            chromeMediaSourceId: streamId
          }
        },
        video: false
      });
      
      const audioCtx = new AudioContext();
      const source = audioCtx.createMediaStreamSource(stream);
      const gainNode = audioCtx.createGain();
      
      source.connect(gainNode);
      gainNode.connect(audioCtx.destination);
      
      audioContexts.set(tabId, { ctx: audioCtx, gainNode: gainNode, stream: stream });
      
    } catch (e) {
      console.error('Failed to capture stream', e);
    }
  } else if (message.type === 'SET_VOLUME') {
    const tabId = message.tabId;
    const volume = message.volume;
    const state = audioContexts.get(tabId);
    
    if (state) {
      state.gainNode.gain.value = volume;
    }
  }
});
