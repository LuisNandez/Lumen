package com.example.client;

import android.app.*;
import android.content.*;
import android.graphics.Bitmap;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.*;
import androidx.media3.common.*;
import androidx.media3.datasource.*;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import org.json.JSONException;
import org.json.JSONObject;
import java.util.*;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Owns the audio device, queue and bookmark independently of the Flutter activity. */
public final class BookAudioService extends Service {
    private static final String CHANNEL = "lumen_book_audio";
    private static final int NOTE = 20714;
    static final String OPEN_BOOK = "com.example.client.OPEN_BOOK";
    private static BookAudioService current;
    private static Map<String,Object> pending;
    private static MethodChannel.Result opening;
    private static final String KEY = "key";
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService covers = Executors.newSingleThreadExecutor();
    private MediaSession session;
    private ExoPlayer player;
    private Map<String,Object> book;
    private List<String> ids = Collections.emptyList(), titles = Collections.emptyList();
    private Bitmap art;
    private String error;
    private boolean foreground;
    private final Runnable releaseIdle = () -> {
        if (player != null && (!player.getPlayWhenReady() || player.getPlaybackState()==Player.STATE_ENDED))
            stopSelf();
    };
    private final Runnable checkpoint = new Runnable() {
        public void run() {
            if (player != null && player.isPlaying()) save();
            handler.postDelayed(this, 4000);
        }
    };

    @SuppressWarnings("unchecked")
    public static void attach(Activity activity, BinaryMessenger messenger) {
        Context app = activity.getApplicationContext();
        new MethodChannel(messenger, "lumen/book_audio").setMethodCallHandler((call,result) -> {
            Map<String,Object> args = call.arguments instanceof Map ?
                (Map<String,Object>)call.arguments : Collections.emptyMap();
            String key = (String)args.get(KEY);
            BookAudioService s = current;
            try {
                switch (call.method) {
                    case "open":
                        if(opening!=null)opening.error("superseded","Se seleccionó otro audiolibro.",null);
                        opening=result;
                        pending = args;
                        Intent start = new Intent(app, BookAudioService.class).setAction("open");
                        if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(start);
                        else app.startService(start);
                        break;
                    case "status":
                        result.success(s != null && s.matches(key) ? s.snapshot() : saved(app,key));
                        break;
                    case "takeLink":
                        Intent launch=activity.getIntent();
                        if(launch != null && OPEN_BOOK.equals(launch.getAction()) && s!=null && s.book!=null) {
                            launch.setAction(Intent.ACTION_MAIN);
                            result.success(s.book.get("detail"));
                        } else result.success(null);
                        break;
                    case "command":
                        if(s != null && (s.matches(key) || (key==null && "stop".equals(args.get("action")))))
                            s.command((String)args.get("action"),((Number)args.getOrDefault("value",0)).longValue());
                        result.success(null); break;
                    default: result.notImplemented();
                }
            } catch(RuntimeException ex) {
                if("open".equals(call.method)){pending=null;opening=null;}
                result.error("book_audio","No se pudo iniciar el reproductor.",null);
            }
        });
    }
    private boolean matches(String key) {
        return key!=null && book!=null && key.equals(book.get(KEY)) && player!=null;
    }
    private static Map<String,Object> saved(Context context,String key) {
        Map<String,Object> value = new HashMap<>();
        if(key==null) return value;
        try {
            String json=context.getSharedPreferences(CHANNEL,MODE_PRIVATE).getString(key,"{}");
            JSONObject j=new JSONObject(json);
            for(Iterator<String> it=j.keys();it.hasNext();){String k=it.next();value.put(k,j.get(k));}
        } catch(JSONException ignored) {}
        return value;
    }

    @Override public void onCreate() {
        super.onCreate();
        current=this;
        if(Build.VERSION.SDK_INT>=26) {
            NotificationChannel ch=new NotificationChannel(CHANNEL,"Reproducción de audiolibros",NotificationManager.IMPORTANCE_LOW);
            ch.setSound(null,null);ch.setShowBadge(false);
            getSystemService(NotificationManager.class).createNotificationChannel(ch);
        }
        session=new MediaSession(this,"Lumen Audiolibros");
        session.setCallback(new MediaSession.Callback(){
            @Override public void onPlay(){command("play",0);}
            @Override public void onPause(){command("pause",0);}
            @Override public void onStop(){command("stop",0);}
            @Override public void onSeekTo(long ms){command("seek",ms);}
            @Override public void onSkipToPrevious(){command("previous",0);}
            @Override public void onSkipToNext(){command("next",0);}
            @Override public void onRewind(){command("relative",-15000);}
            @Override public void onFastForward(){command("relative",15000);}
        });
        session.setSessionActivity(contentIntent());
        handler.post(checkpoint);
    }

    @Override public int onStartCommand(Intent intent,int flags,int startId) {
        String action=intent==null?null:intent.getAction();
        if("open".equals(action) && pending!=null){
            Map<String,Object> next=pending; pending=null;
            save(); releasePlayer(); book=next; art=null; error=null;
            foreground=false;
            postNotification();
            MethodChannel.Result reply=opening;opening=null;
            try{
                open();
                if(reply!=null)reply.success(null);
            }catch(RuntimeException ex){
                if(reply!=null)reply.error("book_audio","No se pudo abrir este audiolibro.",null);
                stopSelf();
            }
        } else if(action!=null && player!=null) command(action,0);
        else if(player==null) stopSelf();
        return START_NOT_STICKY;
    }

    @SuppressWarnings("unchecked")
    private void open() {
        ids=(List<String>)book.get("ids");titles=(List<String>)book.get("titles");
        List<String> urls=(List<String>)book.get("urls");
        if(ids.isEmpty() || urls.size()!=ids.size() || titles.size()!=ids.size())throw new IllegalArgumentException();
        Map<String,String> headers=(Map<String,String>)book.get("headers");
        DefaultHttpDataSource.Factory http=new DefaultHttpDataSource.Factory().setDefaultRequestProperties(headers);
        DefaultDataSource.Factory data=new DefaultDataSource.Factory(this,http);
        ExoPlayer p=new ExoPlayer.Builder(this).setMediaSourceFactory(new DefaultMediaSourceFactory(data)).build();
        player=p;
        p.setAudioAttributes(new AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(),true);
        p.setHandleAudioBecomingNoisy(true);
        p.setWakeMode(C.WAKE_MODE_NETWORK);
        int index=((Number)book.get("index")).intValue();
        long position=0;
        if(index<0) {
            Map<String,Object> mark=saved(this,(String)book.get(KEY));
            index=ids.indexOf(mark.get("track"));
            if(index>=0 && !Boolean.TRUE.equals(mark.get("ended"))) {
                position=((Number)mark.getOrDefault("position",0)).longValue();
            } else index=0;
        }
        List<MediaItem> items=new ArrayList<>(ids.size());
        for(int i=0;i<ids.size();i++)items.add(new MediaItem.Builder().setUri(urls.get(i)).setMediaId(ids.get(i)).build());
        p.setMediaItems(items, Math.min(index,ids.size()-1), Math.max(0,position));
        p.addListener(new Player.Listener(){
            @Override public void onPlayerError(PlaybackException e){
                if(player==p)error="No se pudo reproducir la pista. Comprueba la conexión o la descarga.";
            }
            @Override public void onEvents(Player sender,Player.Events events) {
                if(player!=sender)return;
                handler.removeCallbacks(releaseIdle);
                if(!sender.getPlayWhenReady() || sender.getPlaybackState()==Player.STATE_ENDED)
                    handler.postDelayed(releaseIdle,600000);
                save();publish();
            }
        });
        session.setActive(true);
        p.prepare();p.play();publish();
        String cover=(String)book.get("cover");
        if(cover!=null && !cover.isEmpty()){
            covers.execute(()->{
                Bitmap loaded=BookCover.read(cover,headers);
                handler.post(()->{if(player==p && loaded!=null){art=loaded;publish();}});
            });
        }
    }

    private void command(String action,long value) {
        ExoPlayer p=player;
        if("stop".equals(action)){save();releasePlayer();stopForeground(true);stopSelf();return;}
        if(p==null)return;
        switch(action){
            case "play":
                if(p.getPlaybackState()==Player.STATE_ENDED)p.seekTo(0,0);
                if(p.getPlayerError()!=null){error=null;p.prepare();}
                p.play();break;
            case "pause": p.pause();break;
            case "previous": if(p.hasPreviousMediaItem())p.seekToPreviousMediaItem();else p.seekTo(0);break;
            case "next": if(p.hasNextMediaItem())p.seekToNextMediaItem();break;
            case "jump":
                if(value<0 || value>=ids.size())return;
                p.seekTo((int)value,0); if(p.getPlayerError()!=null){error=null;p.prepare();}p.play();break;
            case "relative": value=p.getCurrentPosition()+value;
            case "seek":
                long max=p.getDuration(); p.seekTo(Math.max(0,max>0?Math.min(max,value):value));break;
            default:return;
        }
        save();publish();
    }

    private Map<String,Object> bookmark(){
        Map<String,Object> out=new HashMap<>();
        if(player==null || player.getMediaItemCount()==0)return out;
        out.put("track", ids.get(player.getCurrentMediaItemIndex()));
        out.put("position",Math.max(0,player.getCurrentPosition()));
        out.put("duration",Math.max(0,player.getDuration()));
        out.put("ended",player.getPlaybackState()==Player.STATE_ENDED);
        return out;
    }
    private void save(){
        if(book==null || player==null || player.getMediaItemCount()==0)return;
        getSharedPreferences(CHANNEL,MODE_PRIVATE).edit().putString((String)book.get(KEY),
            new JSONObject(bookmark()).toString()).apply();
    }
    private Map<String,Object> snapshot(){
        Map<String,Object> out=bookmark();
        out.put("active",true);
        out.put("local",book.get("local"));
        out.put("playing",player.getPlayWhenReady() && error==null && player.getPlaybackState()!=Player.STATE_ENDED);
        if(error!=null)out.put("error",error);
        return out;
    }

    private String chapter(){
        int i=player==null? -1:player.getCurrentMediaItemIndex();
        return i>=0 && i<titles.size()?titles.get(i):"Audiolibro";
    }
    private void publish() {
        if(player==null || book==null)return;
        String chapter=chapter();
        long duration=Math.max(0,player.getDuration());
        MediaMetadata.Builder meta=new MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE,chapter)
            .putString(MediaMetadata.METADATA_KEY_ARTIST,(String)book.get("title"))
            .putString(MediaMetadata.METADATA_KEY_ALBUM,(String)book.get("title"))
            .putString(MediaMetadata.METADATA_KEY_AUTHOR,(String)book.get("author"))
            .putLong(MediaMetadata.METADATA_KEY_DURATION,duration);
        if(art!=null)meta.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART,art);
        session.setMetadata(meta.build());
        long actions=PlaybackState.ACTION_PLAY|PlaybackState.ACTION_PAUSE|PlaybackState.ACTION_PLAY_PAUSE|
            PlaybackState.ACTION_SEEK_TO|PlaybackState.ACTION_REWIND|PlaybackState.ACTION_FAST_FORWARD|PlaybackState.ACTION_STOP;
        if(player.hasPreviousMediaItem())actions|=PlaybackState.ACTION_SKIP_TO_PREVIOUS;
        if(player.hasNextMediaItem())actions|=PlaybackState.ACTION_SKIP_TO_NEXT;
        int state=error!=null?PlaybackState.STATE_ERROR:player.getPlaybackState()==Player.STATE_ENDED?
            PlaybackState.STATE_STOPPED:player.isPlaying()?PlaybackState.STATE_PLAYING:
            player.getPlayWhenReady() && player.getPlaybackState()==Player.STATE_BUFFERING?PlaybackState.STATE_BUFFERING:PlaybackState.STATE_PAUSED;
        session.setPlaybackState(new PlaybackState.Builder().setActions(actions)
            .setState(state,player.getCurrentPosition(),player.isPlaying()?1f:0f).build());
        postNotification();
    }
    private PendingIntent contentIntent() {
        Intent intent=getPackageManager().getLaunchIntentForPackage(getPackageName());
        if(intent==null)intent=getPackageManager().getLeanbackLaunchIntentForPackage(getPackageName());
        if(intent==null)intent=new Intent().setClassName(this,getPackageName()+".MainActivity");
        intent.setAction(OPEN_BOOK).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP|Intent.FLAG_ACTIVITY_CLEAR_TOP);
        return PendingIntent.getActivity(this,NOTE,intent,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
    }
    private Notification.Action action(String verb,int icon,String label){
        Intent i=new Intent(this,BookAudioService.class).setAction(verb);
        PendingIntent pi=PendingIntent.getService(this,0,i,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Action.Builder(icon,label,pi).build();
    }
    private void postNotification(){
        boolean playing=player!=null && player.getPlayWhenReady() && player.getPlaybackState()!=Player.STATE_ENDED && error==null;
        Notification.Builder b=Build.VERSION.SDK_INT>=26?new Notification.Builder(this,CHANNEL):new Notification.Builder(this);
        if(Build.VERSION.SDK_INT>=31)b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE);
        b.setSmallIcon(R.drawable.ic_book_audio).setColor(0xffb20710).setShowWhen(false)
            .setCategory(Notification.CATEGORY_TRANSPORT).setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true).setOngoing(playing).setContentIntent(contentIntent()).setContentTitle(chapter())
            .setContentText(book==null?"Lumen":(String)book.get("title"));
        if(art!=null)b.setLargeIcon(art);
        List<Integer> compact=new ArrayList<>();
        if(player!=null && player.hasPreviousMediaItem()){
            compact.add(compact.size());b.addAction(action("previous",android.R.drawable.ic_media_previous,"Pista anterior"));
        }
        compact.add(compact.size());b.addAction(playing?action("pause",android.R.drawable.ic_media_pause,"Pausar"):
            action("play",android.R.drawable.ic_media_play,"Reproducir"));
        if(player!=null && player.hasNextMediaItem()){
            compact.add(compact.size());b.addAction(action("next",android.R.drawable.ic_media_next,"Pista siguiente"));
        }
        int[] slots=new int[compact.size()];for(int i=0;i<slots.length;i++)slots[i]=i;
        b.setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()).setShowActionsInCompactView(slots));
        Notification n=b.build();
        if(!foreground){startForeground(NOTE,n);foreground=true;}
        else getSystemService(NotificationManager.class).notify(NOTE,n);
    }
    private void releasePlayer(){ExoPlayer old=player;player=null;if(old!=null)old.release();}
    @Override public void onDestroy(){
        save();releasePlayer();handler.removeCallbacksAndMessages(null);covers.shutdownNow();
        session.release();stopForeground(true);if(current==this)current=null;super.onDestroy();
    }
    @Override public void onTaskRemoved(Intent rootIntent){save();super.onTaskRemoved(rootIntent);}
    @Override public IBinder onBind(Intent intent){return null;}
}
