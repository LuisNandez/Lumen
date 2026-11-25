package com.example.client;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import java.io.*;
import java.net.*;
import java.util.Map;

/** Bound both compressed bytes and decoded pixels before sending art to System UI. */
final class BookCover {
    private BookCover() {}
    static Bitmap read(String source, Map<String,String> headers) {
        HttpURLConnection connection=null;
        try{
            Uri uri=Uri.parse(source);
            InputStream input;
            if("file".equals(uri.getScheme()))input=new FileInputStream(uri.getPath());
            else{
                connection=(HttpURLConnection)new URL(source).openConnection();
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(4000);connection.setReadTimeout(5000);
                for(Map.Entry<String,String> h:headers.entrySet())connection.setRequestProperty(h.getKey(),h.getValue());
                if(connection.getResponseCode()!=200)return null;
                input=connection.getInputStream();
            }
            byte[] bytes;
            try(InputStream in=input;ByteArrayOutputStream out=new ByteArrayOutputStream()){
                byte[] buffer=new byte[16384];int n;
                while((n=in.read(buffer))!=-1){
                    if(out.size()+n>12*1024*1024)return null;
                    out.write(buffer,0,n);
                }
                bytes=out.toByteArray();
            }
            BitmapFactory.Options options=new BitmapFactory.Options();
            options.inJustDecodeBounds=true;
            BitmapFactory.decodeByteArray(bytes,0,bytes.length,options);
            options.inJustDecodeBounds=false;options.inSampleSize=1;
            while(Math.max(options.outWidth,options.outHeight)/options.inSampleSize>640)options.inSampleSize*=2;
            return BitmapFactory.decodeByteArray(bytes,0,bytes.length,options);
        }catch(IOException | RuntimeException ignored){return null;}
        finally{if(connection!=null)connection.disconnect();}
    }
}
