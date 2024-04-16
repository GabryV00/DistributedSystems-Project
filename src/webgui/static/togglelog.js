const toggleButtons = document.querySelectorAll('.toggleButton');
const divs = document.querySelectorAll('.file-content');

toggleButtons.forEach(button => {
  button.addEventListener('click', function() {
    const targetId = this.getAttribute('data-target');
    divs.forEach(div => {
      if (div.id === targetId) {
        div.style.display = 'block';
      } else {
        div.style.display = 'none';
      }
    });
  });
});

