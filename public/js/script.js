(function(){

var x, threshold = 150;

function start(evt) {
  x = evt.touches[0].clientX;
}

function move (evt) {
  if (typeof x === 'undefined') return;
  var delta = evt.touches[0].clientX - x;
  if (delta > threshold) {
    cancel();
    document.getElementById('p').click();
  } else if (delta < -threshold) {
    cancel();
    document.getElementById('n').click();
  }
}

function cancel() {
  x = undefined;
}

document.addEventListener('touchstart', start);
document.addEventListener('touchmove', move);
document.addEventListener('touchcancel', cancel);
document.addEventListener('touchend', cancel);

})();
