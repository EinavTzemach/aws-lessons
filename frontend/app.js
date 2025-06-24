// Cognito configuration
const poolData = {
    UserPoolId: 'us-east-2_O99mzImrz',
    ClientId: '34f7lhcodsfddfd7k1dkkuq1ab'
};
const userPool = new AmazonCognitoIdentity.CognitoUserPool(poolData);

// Check authentication on page load
window.onload = function() {
    const cognitoUser = userPool.getCurrentUser();
    if (!cognitoUser) {
        window.location.href = 'login.html';
        return;
    }
    cognitoUser.getSession(function(err, session) {
        if (err || !session.isValid()) {
            window.location.href = 'login.html';
            return;
        }
        // User is authenticated, continue loading the app
        initializeApp(session.getIdToken().getJwtToken());

        // Show logout button and user email
        document.getElementById('userRibbon').style.display = 'flex';
        cognitoUser.getUserAttributes(function(err, attributes) {
          if (!err && attributes) {
            const emailAttr = attributes.find(attr => attr.getName() === 'email');
            if (emailAttr) {
              document.getElementById('userEmail').textContent = emailAttr.getValue();
            }
          }
        });
        document.getElementById('logoutButton').onclick = function() {
          cognitoUser.signOut();
          localStorage.removeItem('idToken');
          window.location.href = 'login.html';
        };
    });
};

function initializeApp(idToken) {
  const uploadForm = document.getElementById('uploadForm');
  const clientIdInput = document.getElementById('clientId');
  const imageFilesInput = document.getElementById('imageFiles');
  const resultsDiv = document.getElementById('results');

  if (!uploadForm || !clientIdInput || !imageFilesInput || !resultsDiv) {
    console.error('One or more required elements not found in the DOM');
    return;
  }

  uploadForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const clientId = clientIdInput.value.trim();
    if (!clientId) {
      alert('נא להזין מזהה לקוח');
      return;
    }
    const files = imageFilesInput.files;
    if (files.length === 0) {
      alert('נא לבחור לפחות תמונה אחת');
      return;
    }
    resultsDiv.innerHTML = '';
    for (const file of files) {
      const formData = new FormData();
      formData.append('clientId', clientId);
      formData.append('image', file);
      try {
        const loadingBox = document.createElement('div');
        loadingBox.className = 'result-box';
        loadingBox.innerHTML = `<h3>${file.name}</h3><p>מעבד תמונה...</p>`;
        resultsDiv.appendChild(loadingBox);
        const res = await fetch('https://q6e9s37x33.execute-api.us-east-2.amazonaws.com/analyze', {
          method: 'POST',
          body: formData,
          headers: {
            'Authorization': idToken
          }
        });
        if (!res.ok) throw new Error(`HTTP error! Status: ${res.status}`);
        const responseText = await res.text();
        let data;
        try {
          data = JSON.parse(responseText);
        } catch (parseError) {
          throw new Error('Invalid response format');
        }
        if (!data || !data.labels) throw new Error('No labels data received');
        resultsDiv.removeChild(loadingBox);
        const box = document.createElement('div');
        box.className = 'result-box';
        box.innerHTML = `
          <h3>${file.name}</h3>
          <ul>
            ${data.labels.map(label => `
              <li>
                <span class="label-name">${label.name}</span> -
                <span class="confidence">${label.confidence.toFixed(1)}%</span>
              </li>`).join('')}
          </ul>`;
        resultsDiv.appendChild(box);
      } catch (err) {
        const errorBox = document.createElement('div');
        errorBox.className = 'result-box error';
        errorBox.innerHTML = `
          <h3>Error processing ${file.name}</h3>
          <p>${err.message || 'An unknown error occurred'}</p>
          <p>Please try again or use a different image.</p>
        `;
        resultsDiv.appendChild(errorBox);
      }
    }
  });
}