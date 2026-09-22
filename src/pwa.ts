// Online-only app. No employee records or API responses are cached by the worker.
if(import.meta.env.PROD&&'serviceWorker' in navigator){
 window.addEventListener('load',()=>{
  void navigator.serviceWorker.register(import.meta.env.BASE_URL+'sw.js',{scope:import.meta.env.BASE_URL,updateViaCache:'none'}).catch(()=>{
   // Browser installation remains optional; registration failure must not block sign-in.
  });
 });
}
